# RocksDB Get

##### InternalKey

在写入数据时会构造一个Internal Key，该Internal Key由User Key、序列号和这次操作的类型组成。在使用`InternalKeyComparator`的过程中，当两个Key相同时（`InternalKeyComparator::Compare`中`r=0`时），说明是相同Key的不同版本，这时就要根据序列号做后续的比较处理。

```cpp
InternalKey(const Slice& _user_key, SequenceNumber s, ValueType t) {
    AppendInternalKey(&rep_, ParsedInternalKey(_user_key, s, t));
}

enum ValueType : unsigned char {
    kTypeDeletion = 0x0,
    kTypeValue = 0x1,
    kTypeMerge = 0x2,
    // ...
}

int InternalKeyComparator::Compare(const ParsedInternalKey& a,
                                   const ParsedInternalKey& b) const {
    int r = user_comparator_->Compare(a.user_key, b.user_key);
    PERF_COUNTER_ADD(user_key_comparison_count, 1);
    if (r == 0) {
        if (a.sequence > b.sequence) {
            r = -1;
        } else if (a.sequence < b.sequence) {
            r = +1;
        } else if (a.type > b.type) {
            r = -1;
        } else if (a.type < b.type) {
            r = +1;
        }
    }
    return r;
}
```

##### LookupKey

由于Internal Key对用户是透明的，当用户传入一个User Key进行查找的时候，会通过LookupKey构建对应的Internal Key：

```cpp
class LookupKey {
    public:
    LookupKey(const Slice& _user_key, SequenceNumber sequence,
              const Slice* ts = nullptr);
    // Return a key suitable for lookup in a MemTable.
    Slice memtable_key() const {
        return Slice(start_, static_cast<size_t>(end_ - start_));
    }

    // Return an internal key (suitable for passing to an internal iterator)
    Slice internal_key() const {
        return Slice(kstart_, static_cast<size_t>(end_ - kstart_));
    }

    // Return the user key
    Slice user_key() const {
        return Slice(kstart_, static_cast<size_t>(end_ - kstart_ - 8));
    }

    // We construct a char array of the form:
    //    klength  varint32               <-- start_
    //    userkey  char[klength]          <-- kstart_
    //    tag      uint64
    //                                    <-- end_
    private:
    const char* start_;
    const char* kstart_;
    const char* end_;
    char space_[200];	 // Avoid allocation for short keys
    //...
};
```

##### Saver

```cpp
struct Saver {
    Status* status;
    const LookupKey* key;
    bool* found_final_value;  // Is value set correctly? Used by KeyMayExist
    bool* merge_in_progress;
    std::string* value;
    SequenceNumber seq;
    std::string* timestamp;
    const MergeOperator* merge_operator;
    // the merge operations encountered;
    MergeContext* merge_context;
    SequenceNumber max_covering_tombstone_seq;
    MemTable* mem;
    Logger* logger;
    Statistics* statistics;
    bool inplace_update_support;
    bool do_merge;
    Env* env_;
    ReadCallback* callback_;
    bool* is_blob_index;
    bool allow_data_in_errors;
    bool CheckCallback(SequenceNumber _seq) {
        if (callback_) {
            return callback_->IsVisible(_seq);
        }
        return true;
    }
};
```



## 具体实现

##### 首先调用DBImpl::Get

这里的`value`使用`PinnableSlice*`替换`std::string* `可以减少一次内存拷贝，提高读性能。 

```cpp
Status DBImpl::Get(const ReadOptions& read_options,
                   ColumnFamilyHandle* column_family, const Slice& key,
                   PinnableSlice* value) {
    return Get(read_options, column_family, key, value, /*timestamp=*/nullptr);
}

Status DBImpl::Get(const ReadOptions& read_options,
                   ColumnFamilyHandle* column_family, const Slice& key,
                   PinnableSlice* value, std::string* timestamp) {
    GetImplOptions get_impl_options;
    get_impl_options.column_family = column_family;
    get_impl_options.value = value;
    get_impl_options.timestamp = timestamp;
    Status s = GetImpl(read_options, key, get_impl_options);
    return s;
}
```

##### 调用DBImpl::GetImpl

`GetImplOption`中制定了读取的CF、Value和时间戳：

```cpp
Status DBImpl::GetImpl(const ReadOptions& read_options, const Slice& key,
                       GetImplOptions& get_impl_options)
```

获取到被读取的CF中的Comparator，对应的ColumnFamilyHandle、ColumnFamilyData：

```cpp
const Comparator* ucmp = get_impl_options.column_family->GetComparator();

auto cfh = static_cast_with_check<ColumnFamilyHandleImpl>(
    get_impl_options.column_family);
auto cfd = cfh->cfd();
```

获取到当前时刻CFD中的SuperVersion（会返回Thread Local Cached One），并进行引用计数：

```cpp
SuperVersion* sv = GetAndRefSuperVersion(cfd);
```

获取当前的序号来决定当前读操作依赖的数据快照：

```cpp
SequenceNumber snapshot;
if (read_options.snapshot != nullptr) { // 如果设置了需要读取某个版本的快照
    if (get_impl_options.callback) {
        snapshot = get_impl_options.callback->max_visible_seq();
    } else {
        snapshot =
            reinterpret_cast<const SnapshotImpl*>(read_options.snapshot)->number_;
    }
} else {
    if (last_seq_same_as_publish_seq_) {
        snapshot = versions_->LastSequence();
    } else {
        snapshot = versions_->LastPublishedSequence();
    }
    if (get_impl_options.callback) {
        get_impl_options.callback->Refresh(snapshot);
        snapshot = get_impl_options.callback->max_visible_seq();
    }
}
if (ts_sz > 0 && !get_impl_options.callback) {
    read_cb.Refresh(snapshot);
    get_impl_options.callback = &read_cb;
}
```

构造一个LookupKey，并尝试从MemTable和Imm MemTable中获取数据的值，可以简单地认为这里的的snapshot就是当前的version最后一次写成功的seq。然后依次在Mem、Imm、SST中查找：

```cpp
// First look in the memtable, then in the immutable memtable (if any).
// s is both in/out. When in, s could either be OK or MergeInProgress.
// merge_operands will contain the sequence of merges in the latter case.
LookupKey lkey(key, snapshot, read_options.timestamp);

// ...

if (!skip_memtable) {
    // 当需要与Key一起获取Value时
    if (get_impl_options.get_value) {
        // 在mem中寻找
        if (sv->mem->Get(lkey, get_impl_options.value->GetSelf(), timestamp, &s,
                         &merge_context, &max_covering_tombstone_seq,
                         read_options, get_impl_options.callback,
                         get_impl_options.is_blob_index)) {
            done = true;
            get_impl_options.value->PinSelf();
        } // 在imm中寻找
        else if ((s.ok() || s.IsMergeInProgress()) &&
                   sv->imm->Get(lkey, get_impl_options.value->GetSelf(),
                                timestamp, &s, &merge_context,
                                &max_covering_tombstone_seq, read_options,
                                get_impl_options.callback,
                                get_impl_options.is_blob_index)) {
            done = true;
            get_impl_options.value->PinSelf();
        }
    } else {	// 不需要与Key一起获取Value
        if (sv->mem->Get(lkey, /*value*/ nullptr, /*timestamp=*/nullptr, &s,
                         &merge_context, &max_covering_tombstone_seq,
                         read_options, nullptr, nullptr, false)) {
            done = true;
        } else if ((s.ok() || s.IsMergeInProgress()) &&
                   sv->imm->GetMergeOperands(lkey, &s, &merge_context,
                                             &max_covering_tombstone_seq,
                                             read_options)) {
            done = true;
        }
    }
    if (!done && !s.ok() && !s.IsMergeInProgress()) {
        ReturnAndCleanupSuperVersion(cfd, sv);
        return s;
    }
}

if (!done) {
    PERF_TIMER_GUARD(get_from_output_files_time);
    // 在SST中找
    sv->current->Get(
        read_options, lkey, get_impl_options.value, timestamp, &s,
        &merge_context, &max_covering_tombstone_seq,
        get_impl_options.get_value ? get_impl_options.value_found : nullptr,
        nullptr, nullptr,
        get_impl_options.get_value ? get_impl_options.callback : nullptr,
        get_impl_options.get_value ? get_impl_options.is_blob_index : nullptr,
        get_impl_options.get_value);
    RecordTick(stats_, MEMTABLE_MISS);
}
```

##### 在MemTable中的查找实现

首先调用`MemTable::Get`：

```cpp
bool MemTable::Get(const LookupKey& key, std::string* value,
                   std::string* timestamp, Status* s,
                   MergeContext* merge_context,
                   SequenceNumber* max_covering_tombstone_seq,
                   SequenceNumber* seq, const ReadOptions& read_opts,
                   ReadCallback* callback, bool* is_blob_index, bool do_merge) {
    // 判断是否有数据要插入
    if (IsEmpty()) {
        return false;
    }
    
    std::unique_ptr<FragmentedRangeTombstoneIterator> range_del_iter(
        NewRangeTombstoneIterator(read_opts,
                                  GetInternalKeySeqno(key.internal_key())));
    if (range_del_iter != nullptr) {
        *max_covering_tombstone_seq =
            std::max(*max_covering_tombstone_seq,
                     range_del_iter->MaxCoveringTombstoneSeqnum(key.user_key()));
    }

    // 获取待查找的Key
    Slice user_key = key.user_key();
    bool found_final_value = false;
    bool merge_in_progress = s->IsMergeInProgress();
    bool may_contain = true;
    size_t ts_sz = GetInternalKeyComparator().user_comparator()->timestamp_size();
    // 判断是否存在布隆过滤器
    if (bloom_filter_) {
        // when both memtable_whole_key_filtering and prefix_extractor_ are set,
        // only do whole key filtering for Get() to save CPU
        if (moptions_.memtable_whole_key_filtering) {
            may_contain =
                bloom_filter_->MayContain(StripTimestampFromUserKey(user_key, ts_sz));
        } else {
            assert(prefix_extractor_);
            may_contain =
                !prefix_extractor_->InDomain(user_key) ||
                bloom_filter_->MayContain(prefix_extractor_->Transform(user_key));
        }
    }
	// 一定不存在的情况下
    if (bloom_filter_ && !may_contain) {
        // iter is null if prefix bloom says the key does not exist
        PERF_COUNTER_ADD(bloom_memtable_miss_count, 1);
        *seq = kMaxSequenceNumber;
    } else {
        if (bloom_filter_) {
            PERF_COUNTER_ADD(bloom_memtable_hit_count, 1);
        }
        // 可能存在的情况下去MemTable中寻找
        GetFromTable(key, *max_covering_tombstone_seq, do_merge, callback,
                     is_blob_index, value, timestamp, s, merge_context, seq,
                     &found_final_value, &merge_in_progress);
    }

    // No change to value, since we have not yet found a Put/Delete
    if (!found_final_value && merge_in_progress) {
        *s = Status::MergeInProgress();
    }
    PERF_COUNTER_ADD(get_from_memtable_count, 1);
    return found_final_value;
}

```

然后调用`MemTable::GetFromTable`，将参数封装在Saver对象中，调用`MemTable::Get`这一方法查找对应的Key：

```cpp
void MemTable::GetFromTable(const LookupKey& key,
                            SequenceNumber max_covering_tombstone_seq,
                            bool do_merge, ReadCallback* callback,
                            bool* is_blob_index, std::string* value,
                            std::string* timestamp, Status* s,
                            MergeContext* merge_context, SequenceNumber* seq,
                            bool* found_final_value, bool* merge_in_progress) {
    Saver saver;
    saver.status = s;
    saver.found_final_value = found_final_value;
    saver.merge_in_progress = merge_in_progress;
    saver.key = &key;
    saver.value = value;
    saver.timestamp = timestamp;
    saver.seq = kMaxSequenceNumber;
    saver.mem = this;
    saver.merge_context = merge_context;
    saver.max_covering_tombstone_seq = max_covering_tombstone_seq;
    saver.merge_operator = moptions_.merge_operator;
    saver.logger = moptions_.info_log;
    saver.inplace_update_support = moptions_.inplace_update_support;
    saver.statistics = moptions_.statistics;
    saver.env_ = env_;
    saver.callback_ = callback;
    saver.is_blob_index = is_blob_index;
    saver.do_merge = do_merge;
    saver.allow_data_in_errors = moptions_.allow_data_in_errors;
    table_->Get(key, &saver, SaveValue);
    *seq = saver.seq;
}
```

##### 在Imm MemTable中的查找实现

在`MemTableListVersion::Get`中调用`GetFromList`，从最新的Imm开始寻找：

```cpp
// Search all the memtables starting from the most recent one.
// Return the most recent value found, if any.
// Operands stores the list of merge operations to apply, so far.
bool MemTableListVersion::Get(const LookupKey& key, std::string* value,
                              std::string* timestamp, Status* s,
                              MergeContext* merge_context,
                              SequenceNumber* max_covering_tombstone_seq,
                              SequenceNumber* seq, const ReadOptions& read_opts,
                              ReadCallback* callback, bool* is_blob_index) {
  return GetFromList(&memlist_, key, value, timestamp, s, merge_context,
                     max_covering_tombstone_seq, seq, read_opts, callback,
                     is_blob_index);
}
```

迭代查找：

```cpp
bool MemTableListVersion::GetFromList(
    std::list<MemTable*>* list, const LookupKey& key, std::string* value,
    std::string* timestamp, Status* s, MergeContext* merge_context,
    SequenceNumber* max_covering_tombstone_seq, SequenceNumber* seq,
    const ReadOptions& read_opts, ReadCallback* callback, bool* is_blob_index) {
    *seq = kMaxSequenceNumber;
    for (auto& memtable : *list) {
        SequenceNumber current_seq = kMaxSequenceNumber;
        bool done = memtable->Get(key, value, timestamp, s, merge_context,
                                  max_covering_tombstone_seq, &current_seq,
                                  read_opts, callback, is_blob_index);
        if (*seq == kMaxSequenceNumber) {
            *seq = current_seq;
        }

        if (done) {
            assert(*seq != kMaxSequenceNumber || s->IsNotFound());
            return true;
        }
        if (!done && !s->ok() && !s->IsMergeInProgress() && !s->IsNotFound()) {
            return false;
        }
    }
    return false;
}
```

##### 在SST中的查找实现

> Note：学习优先级较低，之后再补充

## 备注

在实现的时候，查完未合并的Imm MemTable之后需要再查我们设计的数据结构。

如果要用布隆过滤器可以直接用现成的`DynamicBloom`。







