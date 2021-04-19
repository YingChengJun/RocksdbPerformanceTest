## RocksDB源代码学习

##### 待学习内容：

- [x] Memtable是如何选择不同数据结构实现的，Imm和Mem是怎么封装的
- [x] Get
- [x] Iterator：https://www.jianshu.com/p/f57891ef06e0
- [x] SkipList
- [x] Flush & Compaction，Key判断怎么留下来或者淘汰
- [x] Arena

##### 设计思路

设计一个基于B+树的Rep继承MemTableRep，然后实现里面的基本方法。

在【某个时候】，在后台线程中，通过【合并迭代器（待学习）】将ImmList中的一些ImmTable合并起来，释放掉原有ImmTable的空间，然后将合并后新的ImmTable加入到ImmList中。