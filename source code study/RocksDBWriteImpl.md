## WriteImpl

##### WriteCallback

WriteCallback是一个抽象类，作为一个回调函数。它在写线程执行写操作之前，调用`Callback`方法并返回一个状态，如果状态不是OK那么写操作将会被终止。并且它还控制了该回调对应的写操作是否可以与其他写操作一起批处理。

```cpp
class WriteCallback {
    public:
    virtual Status Callback(DB* db) = 0;
    virtual bool AllowWriteBatching() = 0;
};
```

##### PreReleaseCallback

PreReleaseCallback是一个抽象类，与WriteCallback一样作为回调函数。它在写入WAL后并在写入MemTable之前被触发。它的主要用处在于：在写入对Reader可见之前完成一些操作，或是希望在写线程时通过顺序更新某些内容来减少锁的开销。

```cpp
class PreReleaseCallback {
    public:
    // seq: 该写操作的序列号，之后将被释放
    // is_mem_disabled: 用于debug，其假定该回调函数在正确的WriteQueue中被完成调用
    // log_number: 如果非0，那么其指代的是写入到WAL的编号
    // index: 指定在同一个写线程中，回调的顺序
    // total: 指定回调的总数
    virtual Status Callback(SequenceNumber seq, bool is_mem_disabled,
                            uint64_t log_number, size_t index, size_t total) = 0;
};
```

##### WriteThread::State

State定义了Writer的状态

- STATE_INIT：Writer的初始状态，正在等待加入一个BatchGroup，当其它线程通知它可以成为一个GROUP_LEADER或者。
- STATE_GROUP_LEADER：第一个加入BatchGroup的Writer将成为LEADER，它需要构建一个Write BatchGroup。
- STATE_MEMTABLE_WRITER_LEADER：只在流水线写入时会用到。
- STATE_PARALLEL_MEMTABLE_WRITER：并发写状态，当FOLLOWER是最后一个写完MemTable的线程时，会调用ExitAsBatchGroupLeader，再通知LEADER线程。若不是最后一个写完的，则等待被通知所有写MemTable的操作已经被完成。
- STATE_COMPLETED：终止状态，当PARALLEL LEADER下面所有的FOLLOWER都完成了它们的工作，或是FOLLOWER完成了自己的工作时。
- STATE_LOCKED_WAITING：线程正在等待获取锁。

```cpp
enum State : uint8_t {
    STATE_INIT = 1,
    STATE_GROUP_LEADER = 2,
    STATE_MEMTABLE_WRITER_LEADER = 4,
    STATE_PARALLEL_MEMTABLE_WRITER = 8,
    STATE_COMPLETED = 16,
    STATE_LOCKED_WAITING = 32,
};
```

##### WriteThread::WriteGroup

WriterGroup由一系列的Writer组成，它存储了最早（Oldest）进入和最晚（Newest）进入的Writer，并记录了最后写入的LSN。

```cpp
struct WriteGroup {
    Writer* leader = nullptr;
    Writer* last_writer = nullptr;
    SequenceNumber last_sequence;
    Iterator begin() const { return Iterator(leader, last_writer); }
    Iterator end() const { return Iterator(nullptr, nullptr); }
};
```

##### WriteThread::Writer

WriterGroup中的Writer使用双向链表串联在一起。

```cpp
struct Writer {
    WriteBatch* batch;
    Writer* link_older;
    Writer* link_newer;
    SequenceNumber sequence;	// 写入第一个Key使用的SequenceNumber
    // Other Attrs And Funcs
}
```

在WriteThread中，会标记最新的Writer：

```cpp
// 标记了目前最新等待写入MemTable的Writer
std::atomic<Writer*> newest_writer_;
// 只有在流水线写入开启时有效，标记最新的等待写入MemTable的Writer
std::atomic<Writer*> newest_memtable_writer_;
```

流水线写入开启时，当一个Group的WAL提交后，在执行MemTable写入时下一个Group就会同时开启。

##### WriteThread::JoinBatchGroup()

```cpp
void WriteThread::JoinBatchGroup(Writer* w) {
    // 如果没有其他的Writer在链表中，则转换为GROUP LEADER
    bool linked_as_leader = LinkOne(w, &newest_writer_);
	// 如果被选中为GROUP_LEADER
    if (linked_as_leader) {
        SetState(w, STATE_GROUP_LEADER);
    }
    // 如果没有被选中为GROUP_LEADER，将会调用AwaitState等待自己的状态满足：
    // （1）一个现有的LEADER在完成任务后选择我们作为新的LEADER。
    // （2）一个现有的LEADER选择我们作为FOLLOWER，并且我们单独完成MemTable的写入，或者被LEADER通知使用并发写。
   	// （3）在流水线写入时，一个现有的LEADER选择我们作为它的FOLLOWER，并且已经为我们完成了Book-Keeping和写WAL操作，将我们入队列，成为Pending MemTable Writer。那么之后我们可能会成为写MemTable的LEADER，或一个现有的LEADER叫我们去并发写入到MemTable。
    if (!linked_as_leader) {
        AwaitState(w, STATE_GROUP_LEADER | STATE_MEMTABLE_WRITER_LEADER |
                   STATE_PARALLEL_MEMTABLE_WRITER | STATE_COMPLETED,
                   &jbg_ctx);
    }
}
```



##### DBImpl::WriteImpl





### WriteBuffer写满后的处理

```cpp
Status DBImpl::HandleWriteBufferFull(WriteContext* write_context) {
    mutex_.AssertHeld();
    assert(write_context != nullptr);
    Status status;

    // Before a new memtable is added in SwitchMemtable(),
    // write_buffer_manager_->ShouldFlush() will keep returning true. If another
    // thread is writing to another DB with the same write buffer, they may also
    // be flushed. We may end up with flushing much more DBs than needed. It's
    // suboptimal but still correct.
    ROCKS_LOG_INFO(
        immutable_db_options_.info_log,
        "Flushing column family with oldest memtable entry. Write buffer is "
        "using %" ROCKSDB_PRIszt " bytes out of a total of %" ROCKSDB_PRIszt ".",
        write_buffer_manager_->memory_usage(),
        write_buffer_manager_->buffer_size());
    // no need to refcount because drop is happening in write thread, so can't
    // happen while we're in the write thread
    autovector<ColumnFamilyData*> cfds;
    if (immutable_db_options_.atomic_flush) {
        SelectColumnFamiliesForAtomicFlush(&cfds);
    } else {
        ColumnFamilyData* cfd_picked = nullptr;
        SequenceNumber seq_num_for_cf_picked = kMaxSequenceNumber;

        for (auto cfd : *versions_->GetColumnFamilySet()) {
            if (cfd->IsDropped()) {
                continue;
            }
            if (!cfd->mem()->IsEmpty()) {
                // We only consider active mem table, hoping immutable memtable is
                // already in the process of flushing.
                uint64_t seq = cfd->mem()->GetCreationSeq();
                if (cfd_picked == nullptr || seq < seq_num_for_cf_picked) {
                    cfd_picked = cfd;
                    seq_num_for_cf_picked = seq;
                }
            }
        }
        if (cfd_picked != nullptr) {
            cfds.push_back(cfd_picked);
        }
        MaybeFlushStatsCF(&cfds);
    }

    WriteThread::Writer nonmem_w;
    if (two_write_queues_) {
        nonmem_write_thread_.EnterUnbatched(&nonmem_w, &mutex_);
    }
    for (const auto cfd : cfds) {
        if (cfd->mem()->IsEmpty()) {
            continue;
        }
        cfd->Ref();
        status = SwitchMemtable(cfd, write_context);
        cfd->UnrefAndTryDelete();
        if (!status.ok()) {
            break;
        }
    }
    if (two_write_queues_) {
        nonmem_write_thread_.ExitUnbatched(&nonmem_w);
    }

    if (status.ok()) {
        if (immutable_db_options_.atomic_flush) {
            AssignAtomicFlushSeq(cfds);
        }
        for (const auto cfd : cfds) {
            cfd->imm()->FlushRequested();
        }
        FlushRequest flush_req;
        GenerateFlushRequest(cfds, &flush_req);
        SchedulePendingFlush(flush_req, FlushReason::kWriteBufferFull);
        MaybeScheduleFlushOrCompaction();
    }
    return status;
}
```







