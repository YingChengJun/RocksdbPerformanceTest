## 以Put操作为例说明写操作函数调用流程

```cpp
Status DBImpl::Put(const WriteOptions& o, ColumnFamilyHandle* column_family,
                   const Slice& key, const Slice& val) {
  return DB::Put(o, column_family, key, val);
}
```

【参数1】`WriteOptions`具有以下参数

- `sync`：是否在写入的时候同步转储
- `disableWAL`：不写入WAL
- `ignore_missing_column_families`：当尝试写入到一个不存在的CF时，忽略这个写入请求
- `no_slowdown`：开启后，并且在接收到写入请求时需要等待或者休眠，那么它会马上失败并返回失败状态
- `low_pri`：开启后，如果写入请求后面有接着的合并操作，那么写入请求会被推迟或取消
- `memtable_insert_hint_per_batch`：开启后，在并发批量写入的过程中将会保存每个MemTable最后插入的位置作为提示。如果如果一个写入批处理中的键是连续的，则可以提高并发写入的写入性能。 在非并发写入中，该选项将被忽略。
- `timestamp`：写入的时间戳

【参数2】`ColumnFamilyHandle`保存了一个CF的基本信息，源码如下：

```cpp
class ColumnFamilyHandle {
 public:
  virtual ~ColumnFamilyHandle() {}
  virtual const std::string& GetName() const = 0;
  virtual uint32_t GetID() const = 0;
  virtual Status GetDescriptor(ColumnFamilyDescriptor* desc) = 0;
  virtual const Comparator* GetComparator() const = 0;
};
```

**调用`DB::Put`函数**

`DB::Put`中构建了一个`WriteBatch`，然后在`WriteBatch`中执行PUT操作写入数据：

```cpp
// Pre-allocate size of write batch conservatively.
// 8 bytes are taken by header, 4 bytes for count, 1 byte for type,
// and we allocate 11 extra bytes for key length, as well as value length.
WriteBatch batch(key.size() + value.size() + 24);
Status s = batch.Put(column_family, key, value);
if (!s.ok()) {
    return s;
}
return Write(opt, &batch);
```

`WriteBatchBase`定义了一个写入批处理中的基本操作，里面主要定义了PUT、MERGE、DELETE、SINGLE DELETE等操作的原型。`WriteBatch`继承自`WriteBatchBase`，它包含一个更新集合，这些更新将原子地应用于数据库。

> PUT有一个重载是传入SliceParts，即支持分片KV

**调用`Write`函数**

```cpp
Status DBImpl::Write(const WriteOptions& write_options, WriteBatch* my_batch) {
	return WriteImpl(write_options, my_batch, nullptr, nullptr);
}
```

##### 调用`WriteImpl`函数

参考：[RocksDBWriteImpl](RocksDBWriteImpl.md ':include')

