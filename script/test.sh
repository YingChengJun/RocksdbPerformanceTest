# Compile:
# mv ./build/db_bench ../RocksdbPerformanceTest/db_bench_bp_o?
# cat memtable/bptree_rep.cc | grep order

RunCmd () {
    echo "Start Run Test: key_nums = ${key_nums}, write_buffer_size = ${memtable_size}, min_write_buffer_number_to_merge = ${min_write_buffer_number_to_merge}, compaction_threshold = ${compaction_threshold}, total_write_buf_size=${db_write_buffer_size}"
    ${db_bench} \
    --benchmarks="readrandomwriterandom" \
    --db=${db_dir} \
    --wal_dir=${wal_dir} \
    --readwritepercent=${rw_percent} \
    --num=${key_nums} \
    --duration=${time_execute} \
    --write_buffer_size=${memtable_size} \
    --max_write_buffer_number=${memtable_nums} \
    --num_column_families=${cf_nums} \
    --report_interval_seconds=${report_duration} \
    --report_file=${report_file} \
    --threads=${thread_nums} \
    --max_background_compactions=${thread_compaction_nums} \
    --max_background_flushes=${thread_flush_nums} \
    --min_write_buffer_number_to_merge=${min_write_buffer_number_to_merge} \
    --db_write_buffer_size=${db_write_buffer_size} \
    --disable_wal=true \
    --compaction_threshold=${compaction_threshold}
}

# Run DB Bench
# $1: Use SkipList Or BpTree
# $2: BpTree Order
# $3: Output Report & Log Additional info
RunDbBench () {
    if [ $1 == "SkipList" ];
    then
        echo "Use SkipList"
        db_bench="../db_bench_sk"
        report_file="../reports/db_bench_sk_$3.csv"
        RunCmd
        cp ../db/LOG ../logs/db_bench_sk_$3.log
    elif [ $1 == "BpTree" ];
    then
        echo "Use BpTree, Order = $2"
        db_bench="../db_bench_bp_o$2"
        report_file="../reports/db_bench_bp_$3.csv"
        RunCmd
        cp ../db/LOG ../logs/db_bench_bp_$3.log
    else
        echo "Error Arg!"
    fi
}

# Require Source Common To Init Base Config 
RunOrigin() {
    db_bench="../db_bench_origin"
    report_file="../reports/db_bench_origin_k${key_nums}_m${min_write_buffer_number_to_merge}.csv"
    echo "Start Run Test: key_nums = ${key_nums}, write_buffer_size = ${memtable_size}, min_write_buffer_number_to_merge = ${min_write_buffer_number_to_merge}, total_write_buf_size=${db_write_buffer_size}"
    ${db_bench} \
    --benchmarks="readrandomwriterandom" \
    --db=${db_dir} \
    --wal_dir=${wal_dir} \
    --readwritepercent=${rw_percent} \
    --num=${key_nums} \
    --duration=${time_execute} \
    --write_buffer_size=${memtable_size} \
    --max_write_buffer_number=${memtable_nums} \
    --num_column_families=${cf_nums} \
    --report_interval_seconds=${report_duration} \
    --report_file=${report_file} \
    --threads=${thread_nums} \
    --max_background_compactions=${thread_compaction_nums} \
    --max_background_flushes=${thread_flush_nums} \
    --min_write_buffer_number_to_merge=${min_write_buffer_number_to_merge} \
    --db_write_buffer_size=${db_write_buffer_size} \
    --disable_wal=true
    cp ../db/LOG "../logs/db_bench_origin_k${key_nums}_m${min_write_buffer_number_to_merge}.log"
}

# Run Default Config
Test_0() {
    source common.sh
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
}

# Test different BpTree fan out use
Test_1() {
    source common.sh
    key_nums=1280000
    compaction_threshold=3
    time_execute=1800

    RunOrigin
    RunDbBench SkipList 0 "t2_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunDbBench BpTree 128 "t2_o128_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench BpTree 64 "t2_o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunDbBench BpTree 256 "t2_o256_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunDbBench BpTree 512 "t2_o512_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunDbBench BpTree 32 "t2_o32_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunDbBench BpTree 16 "t2_o16_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunDbBench BpTree 8 "t2_o8_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
}

# Test different key Ranges
Test_2() {
    source common.sh
    time_execute=1200

    # key range = 128W, Default Settings
    key_nums=1280000
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
    # key range = 256W
    key_nums=2560000
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
    # key range = 512W
    # key_nums=5120000
    # RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # RunOrigin
    # key range = 512W
    key_nums=7680000
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
    # key range = 1024W
    key_nums=10240000
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
}

# Test different compaction threshold
Test_3() {
    source common.sh
    # 2 => 1
    compaction_threshold=1
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # 3 => 1, Default Settings
    # 4 => 1
    compaction_threshold=3
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # 5 => 1
    compaction_threshold=4
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    # 6 => 1
    compaction_threshold=5
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
}

# Test Different Min Write Buffer To Merge
Test_4 () {
    source common.sh
    # Max ImmTable numbers = 6
    min_write_buffer_number_to_merge=6
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
    # Max ImmTable numbers = 8, Default Settings
    # Max ImmTable numbers = 10
    min_write_buffer_number_to_merge=10
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
    # Max ImmTable numbers = 12
    min_write_buffer_number_to_merge=12
    RunDbBench BpTree 64 "o64_c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunDbBench SkipList 0 "c${compaction_threshold}_k${key_nums}_m${min_write_buffer_number_to_merge}"
    RunOrigin
}

# Test_0
Test_1
# Test_2
# Test_3
# Test_4