# RocksDBColumnFamily

#### ColumnFamilyHandleImpl

实现了抽象接口ColumnFamilyHandle，客户端可以通过它去访问不同的CF。

创建的时候会传入一个互斥锁（在获取CF描述符以及析构时需要用到该互斥锁），并对ColumnFamilyData调用Ref进行引用计数。它在内部持有一个ColumnFamilyData的引用，ID、Name或是Comparator等信息都从ColumnFamilyData中获取。

析构的时候会进行解引用，并做一些清理。

```cpp
class ColumnFamilyHandleImpl : public ColumnFamilyHandle {
    public:
    ColumnFamilyHandleImpl(
        ColumnFamilyData* cfd, DBImpl* db, InstrumentedMutex* mutex);
    virtual ~ColumnFamilyHandleImpl();
    virtual ColumnFamilyData* cfd() const { return cfd_; }
    virtual uint32_t GetID() const override;
    virtual const std::string& GetName() const override;
    virtual Status GetDescriptor(ColumnFamilyDescriptor* desc) override;
    virtual const Comparator* GetComparator() const override;
    private:
    ColumnFamilyData* cfd_;
    DBImpl* db_;
    InstrumentedMutex* mutex_;
};
```

#### ColumnFamilyHandleInternal

当传入一个ColumnFamilyData时，不调用`Ref()`进行引用。

> 具体设置的机制还不是很懂：
>
> Does not ref-count ColumnFamilyData .We use this dummy ColumnFamilyHandleImpl because sometimes MemTableInserter  calls DBImpl methods. When this happens, MemTableInserter need access to ColumnFamilyHandle (same as the client would need). In that case, we feed MemTableInserter dummy ColumnFamilyHandle and enable it to call DBImpl methods

#### ColumnFamilyData And ColumnFamilySet

ColumnFamilySet中的ColumnFamilyData使用循环双向链表进行串联，当一个CFD被Drop时，它不一定被释放，因为其它的Client可能会持有它的引用。

```cpp
// pointers for a circular linked list. we use it to support iterations over
// all column families that are alive (note: dropped column families can also
// be alive as long as client holds a reference)
ColumnFamilyData* next_;
ColumnFamilyData* prev_;
```

CFD的一些基本属性：

- CFD中保存了指向Version的引用，Version使用双向循环链表串联，`dummy_versions_`为链表头，`current_`即指向链表尾（最新的Version）。
- `log_number_`保存了该CFD中最早的日志编号，更早的日志在数据恢复时将会被忽略。
- 如果该CFD在FlushQueue或者CompactionQueue中，对应地`queued_for_flush_`或`queued_for_compaction_`将为`true`。

```cpp
uint32_t id_;
const std::string name_;
Version* dummy_versions_;
Version* current_;
std::atomic<int> refs_;
std::atomic<bool> initialized_;
std::atomic<bool> dropped_;
MemTable* mem_;
MemTableList imm_;
SuperVersion* super_version_;
std::atomic<uint64_t> super_version_number_;
uint64_t log_number_;
std::atomic<FlushReason> flush_reason_;
std::unique_ptr<CompactionPicker> compaction_picker_;
ColumnFamilySet* column_family_set_;
std::unique_ptr<WriteControllerToken> write_controller_token_;
bool queued_for_flush_;
bool queued_for_compaction_;
uint64_t prev_compaction_needed_bytes_;
bool allow_2pc_;
std::atomic<uint64_t> last_memtable_id_;
std::vector<std::shared_ptr<FSDirectory>> data_dirs_;
bool db_paths_registered_;
```





