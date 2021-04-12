# RocksDB Get

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

获取到当前CFD中最新的SuperVersion（会返回Thread Local Cached One），并进行引用计数

```cpp
SuperVersion* sv = GetAndRefSuperVersion(cfd);
```

