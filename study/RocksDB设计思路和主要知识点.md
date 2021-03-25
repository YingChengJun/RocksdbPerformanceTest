### RocksDB设计思路和主要知识点

**设计思路**

- 通过追加批量写入和日志追加落盘，将随机写变为顺序写的方式，提高写性能
- 将内存中的有序key顺序存储到SStable中，然后进行compact进行多路文件归并操作（应该是查找合并，表现形式貌似是归并），下沉冷数据到高level的SStable文件，清除删除标记的数据清楚<前提是高level中没有该KV记录>，热数据在更新到低级别的level
- memtable+sstable实现LSM tree(Log Structured-Merge Tree)

**基本架构**

- KV结构：

- - Leveldb所处理的每条记录都是一条键值对，由于它基于sequence number提供快照读，准确来说应该是键，序列号，值三元组

    - - 同一个key的新旧数据通过序列号区分（序列号全局递增） 	

- leveldb的层级：

- 向用户提供的DB类接口及其实现，主要是DB、DbImpl、iter等
- 中间概念层的memtable、table、version以及其辅助类，比如对应的iter、builder、VersionEdit等
- 更底层的偏向实际的读写辅助类，比如block、BlockBuilder、WritableFile及其实现等
- 最后是它定义的一些辅助类和实现的数据结构比如它用来表示数据的最小单元Slice、操作状态类Status、memtable中用到的SkipList等

**写入流程**

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/61693BF3DF4142B58BFF84B8777D931C/25469)

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/74ED430C3490460499C1526172C97462/25384)

- KV追加写入日志文件文件，sync文件，然后存储在内存的memtable中，memtable只是一层封装，针对KV的管理是跳表
- 内存中memtable中数据达到阈值，将memtable变为immtable，同时生成新的mmtable
- 将immtable落盘变为level的SStable(有序存储表)，生成的文件记录到version_table<体现在Manifest文件中，Current表明现在有效的Manifest>，level0中不同的SStable中key的范围可能会有重叠
- 当level0中的文件个数达到阈值，发起compact操作，将level0和level1中特定范围内文件进行归并合并，生成新的level1文件
- 等待下次选择合适的level进行合并（level>0的合并条件是按照level中总的文件大小为和是否超过阈值大小为合并条件）<每个level计算合并权值，选择迫切需要合并的level>
- manifest会记载所有SSTable文件的key的范围、level级别

**读流程**

- 读的流程：

- - 在MemTable中查找，无法命中转到下一流程
    - 在immutable_memtable中查找，查找不中转到下一流程
    - 在第0层SSTable中查找，无法命中转到下一流程
    - 在剩余SSTable中查找

- 那么我们接下来的问题是对于第0层以及接下来若干层，如何快速定位key到某个SSTable文件？

- - 对于Level > 1的层级，由于每个SSTable没有交叠，在version中又包含了每个SSTable的key range，你可以使用二分查找快速找到你处于哪两个点之间，再判断这两个点是否属于同一个SSTable，就可以快速知道是否在这一层存在以及存在于哪个SSTable。
    - 对于0层的，看来只能遍历了，所以我们需要控制0层文件的数目。
    - 同时DB还维护了TableCache，用于缓存SSTable文件的句柄和查找的block的位置信息

**磁盘上数据**

- **文件种类**

- - db的操作日志
    - 存储实际数据的SSTable文件
    - DB的元信息Manifest文件
    - 记录当前正在使用的Manifest文件，它的内容就是当前的manifest文件名
    - 系统的运行日志，记录系统的运行信息或者错误日志。
    - 临时数据库文件，repair时临时生成的。

- **log文件结构**

单个log文件由很多的record组成，log以固定block大小为存储单元存储record，block在一个block也可能跨block，结构如下：

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/FD9277350CB44D1FB8BDD28CA040BD4F/25412)

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/9DDB6A65F54D41C08437B0A214A84DCD/25414)

Block := **Record** * N **Record** := Header + Content Header := Checksum + Length + **Type** **Type** := Full **or** First **or** Midder **or** Last

- **SStable文件结构**

- - 大致分为几个部分：

- 数据块 Data Block，直接存储有序键值对

- Meta Block，存储Filter相关信息

- Meta Index Block，对Meta Block的索引，它只有一条记录，key是meta index的名字（也就是Filter的名字），value为指向meta index的位置。

- Index Block，是对Data Block的索引，对于其中的每个记录，其key >=Data Block最后一条记录的key，同时<其后Data Block的第一条记录的key；value是指向data index的位置信息

- Footer，指向各个分区的位置和大小

- - 总体结构如下：

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/368FBB2967584C1E9644222FC925C11D/25473)

- - block的一般结构：

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/15CEB1BF6C1747CEBD070953046420AC/25440)

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/DBECA853533C46DC92130340CD984EB9/25435)

- - Footer结构：

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/108D879EDAAF4F44906A54C843BCBDFF/25444)

- **Manifest文加结构**

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/8FE5081C533C4BECA026E1D976C326BA/25490)

Manifest中应该包含哪些信息：

- coparator名、log编号、前一个log编号、下一个文件编号、上一个序列号，这些都是日志、sstable文件使用到的重要信息，这些字段不一定必然存在。
- 其次是compact点，可能有多个，写入格式为{kCompactPointer, level, internal key}
- 其后是删除文件，可能有多个，格式为{kDeletedFile, level, file number}。
- 最后是新文件，可能有多个，格式为{kNewFile, level, file number, file size, min key, max key}。

**内存中的数据**

- 元数据信息，memtable和immtable

- - 表的操作委托给跳表处理

- 元数据信息：

- - 当前日志句柄
    - 版本管理器、当前的版本信息（对应compaction）和对应的持久化文件标示
    - 当前的全部db配置信息比如comparator及其对应的memtable指针
    - 当前的状态信息以决定是否需要持久化memtable和合并sstable
    - sstable文件集合的信息

**元信息的逻辑**

- 有Version类和VersionSet类

-  Version 

- - Version 表示一个版本的元信息

    - Version中主要包括一个FileMetaData指针的二维数组，分层记录了所有的SST文件信息

    - FileMetaData 数据结构用来维护一个文件的元信息，包括文件大小，文件编号，最大最小值，引用计数等

    - 其中引用计数记录了被不同的Version引用的个数，保证被引用中的文件不会被删除

    - Version中还记录了触发Compaction相关的状态信息，这些信息会在读写请求或Compaction过程中被更新

    - - 在CompactMemTable和BackgroundCompaction过程中会导致新文件的产生和旧文件的删除
        - 每当这个时候都会有一个新的对应的Version生成，并插入VersionSet链表头部
        - LevelDB用VersionEdit来表示这种相邻Version的差值。

- VersionSet

- - VersionSet是一个Version构成的双向链表
    - 这些Version按时间顺序先后产生，记录了当时的元信息
    - 链表头指向当前最新的Version
    - 同时维护了每个Version的引用计数，被引用中的Version不会被删除，其对应的SST文件也因此得以保留，通过这种方式，使得LevelDB可以在一个稳定的快照视图上访问文件
    - VersionSet中除了Version的双向链表外还会记录一些如LogNumber，Sequence，下一个SST文件编号的状态信息

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/47C966A331F84885A4D58B410BECFABD/25522)

- 元数据恢复

- - 为了避免进程崩溃或机器宕机导致的数据丢失，LevelDB需要将元信息数据持久化到磁盘，承担这个任务的就是Manifest文件
    - 每当有新的Version产生都需要更新Manifest
    - 新增数据正好对应于VersionEdit内容，也就是说Manifest文件记录的是一组VersionEdit值，在Manifest中的一次增量内容称作一个Block

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/2ABC9E863637493DABD8EE26ADF52C59/25552)

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/3F41AC59E7154F6E95FCAF1873EA9971/25554)

- - 恢复元信息的过程也变成了依次应用VersionEdit的过程，这个过程中有大量的中间Version产生，但这些并不是我们所需要的
    - LevelDB引入VersionSet::Builder来避免这种中间变量，方法是先将所有的VersoinEdit内容整理到VersionBuilder中，然后一次应用产生最终的Version
    - 过程如下图：

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/4BDF20232664432AB399E78DD5E555EC/25558)

- - - 在库重启时，会首先尝试从Manifest中恢复出当前的元信息状态，过程如下：

- - - - 依次读取Manifest文件中的每一个Block， 将从文件中读出的Record反序列化为VersionEdit；
            - 将每一个的VersionEdit Apply到VersionSet::Builder中，之后从VersionSet::Builder的信息中生成Version；
            - 计算compaction_level_、compaction_score_；
            - 将新生成的Version挂到VersionSet中，并初始化VersionSet的manifest_file_number_， next_file_number_，last_sequence_，log_number_，prev_log_number_ 信息；

**Compact流程**

- LevelDB之所以需要Compaction是有以下几方面原因

- - 数据文件中的被删除的KV记录占用的存储空间需要被回收；
    - 将key存在重合的不同Level的SSTable进行Compaction，可以减少磁盘上的文件数量，提高读取效率

- compaction的时机

- - 定期后台触发compaction任务
    - 正常的读写流程中判定系统达到了一个临界状态，此时必须要进行Compaction

- Leveldb的两种Compaction：

- - minor compaction：将内存immune memtable的数据dump至磁盘上的sstable文件。
    - major compaction：多个level众多SSTable之间的合并。

- 何时判断是否需要compaction

- - minor compaction

    - - immune memtable的数据dump至磁盘sstable文件中

    - major compaction

    - - 启动时，Db_impl.cc::Open()在完成所有的启动准备工作以后，会发起一次Compaction任务。这时是由于还没有开始提供服务，不会造成任何影响，还能够提供之后所有的读效率，一本万利（major compaction）。
        - get 操作时，如果有超过一个 sstable 文件进行了 IO，会检查做 IO 的最后一个文件是否达到了 compact 的条件（ allowed_seeks 用光），达到条件，则主动触发 compact。（major compaction）
        - level0的文件数超过阈值
        - 高于level0的这个level的文件大小总和超过阈值

- level的选择：

- - 计算每个level的合并权值，权值越大，level需要被合并

- level中合并文件的选择

- - 如果某个level的文件被频繁seek，且seek次数变为0，下次从这个文件开始合并
    - 如果没有seek次数等于0，从第一个文件开始进行合并，然后依次往后。
    - 记录上次合并的最大key的值，下次从大于key的位置合并
    - 然后循环遍历合并

- 合并的操作：

- - 获取待合并文件集合

    - - level0：

        - - 找到所有和待合并文范围有重叠的level0的文件，获取level0重叠文件key的范围
            - 在level1中找到的和level0的key范围重叠文件的level1的文件

        - level大于0

        - - 获取该level待合并文加key范围
            - 找到level+1的级别中，找到的和该key范围重叠文件的level+1的文件

    - 合并操作

    - - 如果level>1，并且level+1中没有key重叠的文件，直接将level中文件移到level+1的级别，修改元数据信息

        - 合并操作：

        - - 相同的key是按照seq降序排列的。所以第一个key的是这一次合并中最新的KV
            - 如果最新的该KV操作是删除操作，并且该level以上的级别的SStable文件中没有改KV操作，直接drop该KV记录

**Cache**

- LRUHandle表示了Cache中的每一个元素，通过指针形成一个双向循环链表

- - 同时通过一个next_hash指向（hash_id%hash_size）相同的元素，该结构可以加快搜索，并且只允许有一个相同hash_id的元素，在如插入的时候，如果有相投的hash_id，hash链表和LRU双向链表中删除。
    - 双向链表连接，链接前后元素，最新的在最后

- HandleTable

- - 维护LRUHandle中hash链表

- LRUCache

- - 维护了一个双向循环链表lru_和一个hash表table
    - 当要插入一个元素时，首先将其插入到链表lru的尾部，然后根据hash值将其插入到hash表中

- ShardedLRUCache

- - 通过hash桶维护了多个LRUCache

- 基本拓扑

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/F6CA7C0ED65C4B1999243AE010763752/25687)

- 基本操纵导致的拓扑变化：

- - 假定设置的最大容量为4，即capacity_=4，然后依次向其中插入元素1、5、2、4、9，，并且都在第一个shard中<通过hash计算出来>，简单的示意图如下：
    - 当插入元素1，5, 2, 4后，usage=4。每个元素在hash表中的位置为 list [ hash&length_-1 ] ，由此可知 ，1和5,2和4有着相同的hash值，分别对应list[1]，list[2] 

此时得到如下结果（为简化，与循环链表头部相连的部分指针线未画出）

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/BD61C2317D644044AE859B63356D7D17/25686)

- 时已达到最大容量，假设要继续插入一个元素9（对应list[1]），插入9后，usage>capacity，则要从链表头部开始移除元素，即元素1会被移除，得到结果如下：

​    ![0](https://note.youdao.com/yws/public/resource/60b7e3aa14a01c85d05ee8a7e4d16c46/xmlnote/6DD986B29E444C9B8DDA38B1011AD1FA/25688)

**其他**

- Open开始 => 检查是否有CURRENT文件 => 没有的话, 新建数据库 => 回放MANIFEST, 归并VersionEdit到一个新Version => 收集.log文件, 回放日志 => 如果memtable满了要compact, 没满可以复用日志 => 重写MANIFEST => 清除无用文件 => Open结束.

- CAP

- - C = Consistency 一致性	
    - A = Availability 可用性
    - P = Partition tolerance 分区容错性
    - 三者最多取其二, 这个我从来没看过证明论文, 但几乎是不言自明的. 要P就要有副本在不同的机器上, 那更新一个数据, 就要同步到副本. 这时候只能在C和A之中选一个. 如果选C, 那么必须等所有副本确认同步完成之后, 才能再次提供服务, 系统就锁死(不可用)了. 如果选A, 那么就存在着副本版本不同步的问题.

- 之所以要把Snapshot串联起来是为了知道Snapshot的SequenceNumber最小是多少, 先记作MIN_SEQ. 在compaction中, 如果遇到KV的SequenceNumber比MIN_SEQ大, 那无论如何这个KV就不能被清除掉. 因为这段数据正在被某个快照保护着.