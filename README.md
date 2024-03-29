# RocksDB Performance Test

##### 不同线程数的性能曲线：

- 随着前台线程数增加，发生性能抖动的次数也越多(频率更高)，推测的原因是前台多线程的并发写入能够提高整体的数据写入量，也就会有更多的Flush和Compaction操作，从而造成更多的性能抖动。
- 随着前台线程数增加，整个系统的吞吐量上升，但是前台32线程时整体性能反而不如16线程（16核系统，线程调度）
不同读写比的性能曲线：
- 随着读写比例的降低（读越少写越多），发生性能抖动的次数也越多(频率更高)，推测的原因是更多的数据写入需要更多的Flush和Compaction的操作

##### 不同memtable大小的性能曲线：

- 随着memtable大小的增大，发生性能抖动的次数越少（频率更低），推测的原因是内存的memtable中能够保留更多写入的数据，也就更少需要Flush和Compaction操作
- 随着memtable大小的增大，整体的性能有所提升，推测的原因是大部分数据存留在内存中，并且可以在内存中读取到。推测当memtable的大小足够大时，整体的吞吐量会趋向稳定。

##### 不同memtable数量的性能曲线：

- 在所有的memtable总大小一定的情况下，memtable数量的增多（每个memtable的size减少），会使得memtable更快被写满，就会需要更多的Flush和Compaction操作，发生抖动的频率也越高。
- 从性能上来看，memtable数量越多，查询的层数越多，会更加不利于查询。

##### 不同cf数量的性能曲线：



----

##### 其他备注

- `InstallSuperVersion `函数：更新维护整个LSM形状，可以把LSM的形状打在日志里再分析
