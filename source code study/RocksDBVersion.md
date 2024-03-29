# RocksDB Version

#### VersionStorageInfo

VersionStorageInfo是Version的信息存储结构，每个Version的SST文件信息都存储在VersionStorageInfo中。、

> Note：学习的优先级较低，之后再补充

#### Version

这个是RocksDB内部概念。一个版本包含某个时间点的所有存活SST文件。一旦一个落盘或者压缩完成，由于存活SST文件发生了变化，一个新的“版本”会被创建。一个旧的“版本”还会被仍在进行的读请求或者压缩工作使用。旧的版本最终会被回收。

> Note：学习的优先级较低，之后再补充

#### SuperVersion

RocksDB的内部概念。一个超级版本包含一个特定时间的 的 一个SST文件列表（一个“版本”）以及一个存活memtable的列表。不管是压缩还是落盘，抑或是一个memtable切换，都会生成一个新的“超级版本”。一个旧的“超级版本”会被继续用于正在进行的读请求。旧的超级版本最终会在不再需要的时候被回收掉。

SuperVersion是DB的一个完整版本，它包含所有的信息：当前的MemTable、Imm MemTable和一个Version（包含SST的数据信息）的引用。访问SuperVersion中的成员不是线程安全的，需要额外加锁。

![image-20210409233219632](RocksDBVersion.assets/image-20210409233219632.png)

- `cfd`表示该SuperVersion所指向的CFD：CFD和SuperVersion是一对多的关系，一个CFD中可能会存在多个SuperVersion（一个是最新的，其它的是旧的），因此一个SuperVersion可以唯一确定一个CFD。

![image-20210411202109290](RocksDBVersion.assets/image-20210411202109290.png)

- `mutable_cf_options`包含了一些可以更改的配置，比如`max_write_buffer_number`。
- `mem`指向了该CF中的MemTable，`imm`指向了该CF中的Imm MemTable的列表。在一个CF中只有一个MemTable，但允许存在多个Imm MemTable。
- `current`中存储了有关SST的信息。
- `to_delete`的作用主要体现在清理阶段的`CleanUp()`中，`imm->Unref()`会返回所有所有需要释放的MemTable并存储在这个数组中，然后会在析构时释放该数组中的MemTable。此过程不需要加锁。
- 调用`CleanUp()`和`init()`方法时需要加锁。

```cpp
struct SuperVersion {
    ColumnFamilyData* cfd;
    MemTable* mem;
    MemTableListVersion* imm;
    Version* current;
    MutableCFOptions mutable_cf_options;
    uint64_t version_number;
    WriteStallCondition write_stall_condition;
    InstrumentedMutex* db_mutex;
    SuperVersion() = default;
    ~SuperVersion();
    SuperVersion* Ref();
    bool Unref();
    void Cleanup();
    void Init(ColumnFamilyData* new_cfd, MemTable* new_mem,
              MemTableListVersion* new_imm, Version* new_current);
    static int dummy;
    static void* const kSVInUse;
    static void* const kSVObsolete;

    private:
    std::atomic<uint32_t> refs;
    autovector<MemTable*> to_delete;
};
```

#### VersionSet

VersionSet是整个DB的版本管理，它维护着MANIFEST文件。每个CF的版本单独管理。

> Note：学习的优先级较低，之后再补充