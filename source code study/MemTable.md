# MemTable

#### MemTable



#### MemTableListVersion



#### MemTableRep

MemTableRep是使用不同数据结构的MemTable实现的基类，RocksDB在MemTableRep的基础上实现SkipListRep、HashSkipListRep、VectorRep，即为MemTable提供了跳跃表、哈希跳跃表和向量的数据结构实现。其使用了工厂方法模式，类之间的关系图如下：

![image-20210413231726891](MemTable.assets/image-20210413231726891.png)

各个具体的Factory通过实现CreateMemTableRep方法来生成具体的Rep对象，可以通过传入不同的键比较器或者其他的参数来生成不同的Rep对象。生成的Rep对象将会被传入到MemTable中，作为MemTable的数据结构：

```cpp
// MemTable中维护了一个插入Rep和范围删除Rep
class MemTable {
    private:
    std::unique_ptr<MemTableRep> table_;
  	std::unique_ptr<MemTableRep> range_del_table_;
}
```

MemTableRep的定义如下：

```cpp
class MemTableRep {
    public:
    class KeyComparator {
        public:
        typedef ROCKSDB_NAMESPACE::Slice DecodedType;
        virtual DecodedType decode_key(const char* key) const {
            return GetLengthPrefixedSlice(key);
        }
        virtual int operator()(const char* prefix_len_key1,
                               const char* prefix_len_key2) const = 0;
        virtual int operator()(const char* prefix_len_key,
                               const Slice& key) const = 0;
        virtual ~KeyComparator() {}
    };
    explicit MemTableRep(Allocator* allocator) : allocator_(allocator) {}
    virtual KeyHandle Allocate(const size_t len, char** buf);
    virtual void Insert(KeyHandle handle) = 0;
    virtual bool InsertKey(KeyHandle handle) {
        Insert(handle);
        return true;
    }
    virtual void InsertWithHint(KeyHandle handle, void** /*hint*/) {
        Insert(handle);
    }
    virtual bool InsertKeyWithHint(KeyHandle handle, void** hint) {
        InsertWithHint(handle, hint);
        return true;
    }
    virtual void InsertWithHintConcurrently(KeyHandle handle, void** /*hint*/) {
        // Ignore the hint by default.
        InsertConcurrently(handle);
    }
    virtual bool InsertKeyWithHintConcurrently(KeyHandle handle, void** hint) {
        InsertWithHintConcurrently(handle, hint);
        return true;
    }
    virtual void InsertConcurrently(KeyHandle handle);
    virtual bool InsertKeyConcurrently(KeyHandle handle) {
        InsertConcurrently(handle);
        return true;
    }
    virtual bool Contains(const char* key) const = 0;
    virtual void MarkReadOnly() {}
    virtual void MarkFlushed() {}
    virtual void Get(const LookupKey& k, void* callback_args,
                     bool (*callback_func)(void* arg, const char* entry));
    virtual uint64_t ApproximateNumEntries(const Slice& /*start_ikey*/,
                                           const Slice& /*end_key*/) {
        return 0;
    }
    virtual size_t ApproximateMemoryUsage() = 0;
    virtual ~MemTableRep() {}
    class Iterator {
        public:
        virtual ~Iterator() {}
        virtual bool Valid() const = 0;
        virtual const char* key() const = 0;
        virtual void Next() = 0;
        virtual void Prev() = 0;
        virtual void Seek(const Slice& internal_key, const char* memtable_key) = 0;
        virtual void SeekForPrev(const Slice& internal_key,
                                 const char* memtable_key) = 0;
        virtual void SeekToFirst() = 0;
        virtual void SeekToLast() = 0;
    };
    virtual Iterator* GetIterator(Arena* arena = nullptr) = 0;
    virtual Iterator* GetDynamicPrefixIterator(Arena* arena = nullptr) {
        return GetIterator(arena);
    }
    virtual bool IsMergeOperatorSupported() const { return true; }
    virtual bool IsSnapshotSupported() const { return true; }

    protected:
    virtual Slice UserKey(const char* key) const;
    Allocator* allocator_;
};
```

#### SkipListRep & InlineSkipList

SkipListRep持有了一个InlineSkipList对象，通过调用InlineSkipList中的方法来实现MemTable的操作：

```cpp
class SkipListRep : public MemTableRep {
    InlineSkipList<const MemTableRep::KeyComparator&> skip_list_;
}
```

![image-20210414140750606](MemTable.assets/image-20210414140750606.png)

##### InlineSkipList::Node

在Node中将Key和链表每层的指针连续存储，相比于Key存指针的优势在于：减少部分内存的使用，并且可以更好地利用Cache的局部性。

`next_[0]`用于存储高度，`next_[i](i>1)`表示指向第`i`层后面一个Node的指针，`next_[1]`及之后的内存空间用于存储Key：

> RocksDB在new新节点时会把height写在next_[0]的前4个字节处，然后将这个节点插入的时候再读出来，这时候next_[0]又变成了一个指针。

![image-20210414141720866](MemTable.assets/image-20210414141720866.png)

```cpp
struct InlineSkipList<Comparator>::Node {
    private:
    std::atomic<Node*> next_[1];
};
```

##### InlineSkipList::Splice

在非并发写入的情况下，`prev_`和`next_`是一个由`Node*`构成的数组，它保存了上一次遍历时每层`prev`和`next`的位置，并且一定满足`prev_[i+1].key <= prev_[i].key < next_[i].key <= next_[i+1]`（画个图就能理解），即低层的范围一定比高层小。

在插入时，会从低层到高层遍历 `Splice`，若发现某一层包围了 `key`，说明更高的层都一定包围了这个`Key`，因此从这层开始遍历即可。

```cpp
struct InlineSkipList<Comparator>::Splice {
    int height_ = 0;
    Node** prev_;
    Node** next_;
};
```

##### InlineSkipList中一些常见的比较查找函数

```cpp
// Return true if key is greater than the data stored in "n".  Null n
// is considered infinite.  n should not be head_.
bool KeyIsAfterNode(const char* key, Node* n) const;
bool KeyIsAfterNode(const DecodedKey& key, Node* n) const;

// Returns the earliest node with a key >= key.
// Return nullptr if there is no such node.
Node* FindGreaterOrEqual(const char* key) const;

// Return the latest node with a key < key.
// Return head_ if there is no such node.
// Fills prev[level] with pointer to previous node at "level" for every
// level in [0..max_height_-1], if prev is non-null.
Node* FindLessThan(const char* key, Node** prev = nullptr) const;

// Return the latest node with a key < key on bottom_level. Start searching
// from root node on the level below top_level.
// Fills prev[level] with pointer to previous node at "level" for every
// level in [bottom_level..top_level-1], if prev is non-null.
Node* FindLessThan(const char* key, Node** prev, Node* root, int top_level,
                   int bottom_level) const;

// Return the last node in the list.
// Return head_ if list is empty.
Node* FindLast() const;

// Traverses a single level of the list, setting *out_prev to the last
// node before the key and *out_next to the first node after. Assumes
// that the key is not present in the skip list. On entry, before should
// point to a node that is before the key, and after should point to
// a node that is after the key.  after should be nullptr if a good after
// node isn't conveniently available.
template<bool prefetch_before>
void FindSpliceForLevel(const DecodedKey& key, Node* before, Node* after, int level,
                        Node** out_prev, Node** out_next);

// Recomputes Splice levels from highest_level (inclusive) down to
// lowest_level (inclusive).
void RecomputeSpliceLevels(const DecodedKey& key, Splice* splice,
                           int recompute_level);
```

##### 随机高度生成

以 1 / kBranching 的概率生成提升高度（默认为1/4），其原理是随机生成一个随机数`rnd->next()`，当这个值小于等于`Random::kMaxNext + 1) / kBranching_`（即`kScaledInverseBranching_`）时，会提升高度，大于时不提升高度。按照均匀概率分布，其提升的概率就是 1 / kBranching 。

```cpp
int InlineSkipList<Comparator>::RandomHeight() {
    auto rnd = Random::GetTLSInstance();

    int height = 1;
    while (height < kMaxHeight_ && height < kMaxPossibleHeight &&
           rnd->Next() < kScaledInverseBranching_) {
        height++;
    }
    assert(height > 0);
    assert(height <= kMaxHeight_);
    assert(height <= kMaxPossibleHeight);
    return height;
}
```



## 备注

在实现我们设置的新的数据结构时，创建一个新的Rep继承MemTableRep，然后实现里面的一些方法。

TODO：具体的使用方式参考IMM的设计