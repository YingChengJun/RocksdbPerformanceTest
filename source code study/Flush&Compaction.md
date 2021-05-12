# RocksDB Flush

在RocksDB中，Flush是以Column Family为单位进行的。在全局的DBImpl中包含了一个Flush队列，这个队列保存所有将要被Flush到磁盘中的Column Family。

```cpp
class DBImpl {
    std::deque<ColumnFamilyData*> flush_queue_;
};
```

### `DBImpl::SchedulePendingFlush`

将`flush_req`（里面有CFD）添加到Flush队列`flush_queue_`中

```cpp
void DBImpl::SchedulePendingFlush(const FlushRequest& flush_req,
                                  FlushReason flush_reason) {
    if (flush_req.empty()) {
        return;
    }
    for (auto& iter : flush_req) {
        ColumnFamilyData* cfd = iter.first;
        cfd->Ref();
        cfd->SetFlushReason(flush_reason);
    }
    ++unscheduled_flushes_;
    flush_queue_.push_back(flush_req);
}
```

### `DBImpl::MaybeScheduleFlushOrCompaction`

```cpp
void DBImpl::MaybeScheduleFlushOrCompaction() {
  mutex_.AssertHeld();
  if (!opened_successfully_) {
    // Compaction may introduce data race to DB open
    return;
  }
  if (bg_work_paused_ > 0) {
    // we paused the background work
    return;
  } else if (error_handler_.IsBGWorkStopped() &&
             !error_handler_.IsRecoveryInProgress()) {
    // There has been a hard error and this call is not part of the recovery
    // sequence. Bail out here so we don't get into an endless loop of
    // scheduling BG work which will again call this function
    return;
  } else if (shutting_down_.load(std::memory_order_acquire)) {
    // DB is being deleted; no more background compactions
    return;
  }
  auto bg_job_limits = GetBGJobLimits();
  // Note: 此处判断了线程池是否有高优先级的线程
  bool is_flush_pool_empty =
    env_->GetBackgroundThreads(Env::Priority::HIGH) == 0;
  while (!is_flush_pool_empty && unscheduled_flushes_ > 0 &&
         bg_flush_scheduled_ < bg_job_limits.max_flushes) {
    bg_flush_scheduled_++;
    FlushThreadArg* fta = new FlushThreadArg;
    fta->db_ = this;
    fta->thread_pri_ = Env::Priority::HIGH;
    // Note: 此处调度了一个后台线程来执行Flush操作
    // 第一个参数function是该线程被调度时执行的函数
    // 第二个参数arg是要传入到函数中的参数
    // 第三个参数是该线程的优先级
    // 第五个参数是该线程被取消调度时执行的函数，UnscheduleFlushCallback的作用是释放fta的空间
    env_->Schedule(&DBImpl::BGWorkFlush, fta, Env::Priority::HIGH, this,
                   &DBImpl::UnscheduleFlushCallback);
    --unscheduled_flushes_;
    TEST_SYNC_POINT_CALLBACK(
      "DBImpl::MaybeScheduleFlushOrCompaction:AfterSchedule:0",
      &unscheduled_flushes_);
  }

  // special case -- if high-pri (flush) thread pool is empty, then schedule
  // flushes in low-pri (compaction) thread pool.
  if (is_flush_pool_empty) {
    while (unscheduled_flushes_ > 0 &&
           bg_flush_scheduled_ + bg_compaction_scheduled_ <
           bg_job_limits.max_flushes) {
      bg_flush_scheduled_++;
      FlushThreadArg* fta = new FlushThreadArg;
      fta->db_ = this;
      fta->thread_pri_ = Env::Priority::LOW;
      env_->Schedule(&DBImpl::BGWorkFlush, fta, Env::Priority::LOW, this,
                     &DBImpl::UnscheduleFlushCallback);
      --unscheduled_flushes_;
    }
  }

  if (bg_compaction_paused_ > 0) {
    // we paused the background compaction
    return;
  } else if (error_handler_.IsBGWorkStopped()) {
    // Compaction is not part of the recovery sequence from a hard error. We
    // might get here because recovery might do a flush and install a new
    // super version, which will try to schedule pending compactions. Bail
    // out here and let the higher level recovery handle compactions
    return;
  }

  if (HasExclusiveManualCompaction()) {
    // only manual compactions are allowed to run. don't schedule automatic
    // compactions
    TEST_SYNC_POINT("DBImpl::MaybeScheduleFlushOrCompaction:Conflict");
    return;
  }

  while (bg_compaction_scheduled_ < bg_job_limits.max_compactions &&
         unscheduled_compactions_ > 0) {
    CompactionArg* ca = new CompactionArg;
    ca->db = this;
    ca->prepicked_compaction = nullptr;
    bg_compaction_scheduled_++;
    unscheduled_compactions_--;
    env_->Schedule(&DBImpl::BGWorkCompaction, ca, Env::Priority::LOW, this,
                   &DBImpl::UnscheduleCompactionCallback);
  }
}
```

在`env_Schedule`中其最终会调用`DBImpl::BackgroundFlush`函数：

```cpp
Status DBImpl::BackgroundFlush(bool* made_progress, JobContext* job_context,
                               LogBuffer* log_buffer, FlushReason* reason,
                               Env::Priority thread_pri) {
    // 遍历FlushQueue，找到要被刷新到磁盘的ColumnFamily
    while (!flush_queue_.empty()) {
        const FlushRequest& flush_req = PopFirstFromFlushQueue();
        superversion_contexts.clear();
        superversion_contexts.reserve(flush_req.size());

        for (const auto& iter : flush_req) {
            ColumnFamilyData* cfd = iter.first;
            if (cfd->IsDropped() || !cfd->imm()->IsFlushPending()) {
                column_families_not_to_flush.push_back(cfd);
                continue;
            }
            superversion_contexts.emplace_back(SuperVersionContext(true));
            bg_flush_args.emplace_back(cfd, iter.second,
                                       &(superversion_contexts.back()));
        }
        if (!bg_flush_args.empty()) {
            break;
        }
    }

    if (!bg_flush_args.empty()) {
        auto bg_job_limits = GetBGJobLimits();
        for (const auto& arg : bg_flush_args) {
            ColumnFamilyData* cfd = arg.cfd_;
        }
        // Flush这个Mem到磁盘中
        status = FlushMemTablesToOutputFiles(bg_flush_args, made_progress,
                                             job_context, log_buffer, thread_pri);
        *reason = bg_flush_args[0].cfd_->GetFlushReason();
        for (auto& arg : bg_flush_args) {
            ColumnFamilyData* cfd = arg.cfd_;
            if (cfd->UnrefAndTryDelete()) {
                arg.cfd_ = nullptr;
            }
        }
    }
}
```

### 可以触发Flush的四个函数

它们都调用了`SwitchMemtable`，每一次调用`SwitchMemtable`之后，都会调用对应Imm的`FlushRequested`函数来设置对应Mem的`flush_requeseted`, 并且会调用上面的`SchedulePendingFlush`来将对应的ColumnFamily加入到`flush_queue_`队列中。

##### 一、`DBImpl::HandleWriteBufferFull`：在`DBImpl::PreprocessWrite`中被调用

```cpp
Status DBImpl::PreprocessWrite(const WriteOptions& write_options,
                               bool* need_log_sync,
                               WriteContext* write_context) {  
    //...
    if (UNLIKELY(status.ok() && write_buffer_manager_->ShouldFlush())) {
        // Before a new memtable is added in SwitchMemtable(),
        // write_buffer_manager_->ShouldFlush() will keep returning true. If another
        // thread is writing to another DB with the same write buffer, they may also
        // be flushed. We may end up with flushing much more DBs than needed. It's
        // suboptimal but still correct.
        WaitForPendingWrites();
        status = HandleWriteBufferFull(write_context);
    }
    //...
}
```

函数的核心代码：

```cpp
Status DBImpl::HandleWriteBufferFull(WriteContext* write_context) {
    // ...
    for (auto cfd : *versions_->GetColumnFamilySet()) {
        if (cfd->IsDropped()) {
            continue;
        }
        if (!cfd->mem()->IsEmpty()) {
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
    // ...
    for (const auto cfd : cfds) {
        if (cfd->mem()->IsEmpty()) {
            continue;
        }
        cfd->Ref();
        // 为这些CFD切换MemTable
        status = SwitchMemtable(cfd, write_context);
        cfd->UnrefAndTryDelete();
        if (!status.ok()) {
            break;
        }
    }
    //...
    if (status.ok()) {
        if (immutable_db_options_.atomic_flush) {
            AssignAtomicFlushSeq(cfds);
        }
        for (const auto cfd : cfds) {
            // 标记Imm需要被Flush
            cfd->imm()->FlushRequested();
        }
        FlushRequest flush_req;
        // 生成flush_req
        GenerateFlushRequest(cfds, &flush_req);
        //将flush_req添加到Flush队列flush_queue_中
        SchedulePendingFlush(flush_req, FlushReason::kWriteBufferFull);
        MaybeScheduleFlushOrCompaction();
    }
}
```

##### 二、`DBImpl::SwitchWAL`：在`DBImpl::PreprocessWrite`中被调用

```cpp
Status DBImpl::PreprocessWrite(const WriteOptions& write_options,
                               bool* need_log_sync,
                               WriteContext* write_context) {  
    //...
    if (UNLIKELY(status.ok() && !single_column_family_mode_ &&
                 total_log_size_ > GetMaxTotalWalSize())) {
        WaitForPendingWrites();
        status = SwitchWAL(write_context);
    }
    //...
}
```

函数的核心代码，后续调用流程与上面一个基本一致：

```cpp
Status DBImpl::SwitchWAL(WriteContext* write_context) {
    //...
    if (immutable_db_options_.atomic_flush) {
        SelectColumnFamiliesForAtomicFlush(&cfds);
    } else {
        // 找到拥有最老WAL的CF进行替换
        for (auto cfd : *versions_->GetColumnFamilySet()) {
            if (cfd->IsDropped()) {
                continue;
            }
            if (cfd->OldestLogToKeep() <= oldest_alive_log) {
                cfds.push_back(cfd);
            }
        }
        MaybeFlushStatsCF(&cfds);
    }

    for (const auto cfd : cfds) {
        cfd->Ref();
        status = SwitchMemtable(cfd, write_context);
        cfd->UnrefAndTryDelete();
        if (!status.ok()) {
            break;
        }
    }
    if (status.ok()) {
        if (immutable_db_options_.atomic_flush) {
            AssignAtomicFlushSeq(cfds);
        }
        for (auto cfd : cfds) {
            cfd->imm()->FlushRequested();
        }
        FlushRequest flush_req;
        GenerateFlushRequest(cfds, &flush_req);
        SchedulePendingFlush(flush_req, FlushReason::kWriteBufferManager);
        MaybeScheduleFlushOrCompaction();
    }
    return status;
}
```

##### 三、`DBImpl::FlushMemTable`：由用户调用，强制刷新

##### 四、`DBImpl::ScheduleFlushes`：在`DBImpl::PreprocessWrite`中被调用

```cpp
Status DBImpl::PreprocessWrite(const WriteOptions& write_options,
                               bool* need_log_sync,
                               WriteContext* write_context) {  
    if (UNLIKELY(status.ok() && !flush_scheduler_.Empty())) {
        WaitForPendingWrites();
        status = ScheduleFlushes(write_context);
    }
}
```

函数的核心代码，后续调用流程与上面一个基本一致：

```cpp
Status DBImpl::ScheduleFlushes(WriteContext* context) {
    autovector<ColumnFamilyData*> cfds;
    if (immutable_db_options_.atomic_flush) {
        SelectColumnFamiliesForAtomicFlush(&cfds);
        for (auto cfd : cfds) {
            cfd->Ref();
        }
        flush_scheduler_.Clear();
    } else {
        ColumnFamilyData* tmp_cfd;
        while ((tmp_cfd = flush_scheduler_.TakeNextColumnFamily()) != nullptr) {
            cfds.push_back(tmp_cfd);
        }
        MaybeFlushStatsCF(&cfds);
    }
	//...
    for (auto& cfd : cfds) {
        if (!cfd->mem()->IsEmpty()) {
            status = SwitchMemtable(cfd, context);
        }
        if (cfd->UnrefAndTryDelete()) {
            cfd = nullptr;
        }
        if (!status.ok()) {
            break;
        }
    }
	//...
    if (status.ok()) {
        if (immutable_db_options_.atomic_flush) {
            AssignAtomicFlushSeq(cfds);
        }
        FlushRequest flush_req;
        GenerateFlushRequest(cfds, &flush_req);
        SchedulePendingFlush(flush_req, FlushReason::kWriteBufferFull);
        MaybeScheduleFlushOrCompaction();
    }
    return status;
}
```



# RocksDB Compaction