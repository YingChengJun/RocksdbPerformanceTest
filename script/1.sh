# 不同的读写比例测试
source "./common.sh"

# Default
rw_percent=95
op_nums=10000000
time_execute=1800
# Column Family
cf_nums=4 
# Memtable
memtable_size=$((128*1024*1024))
memtable_nums=4
min_write_buffer_number_to_merge=2
# Thread
thread_nums=16
thread_compaction_nums=4
thread_flush_nums=4
# Report
report_duration=1

echo "开始测试读写性能"
echo """本次测试的配置:
readwritepercent=${rw_percent}%,
write_buffer_size=${memtable_size}B,
max_write_buffer_number=${memtable_nums},
num_column_families=${cf_nums},
threads=${thread_nums},
max_background_compactions=${thread_compaction_nums},
max_background_flushes=${thread_flush_nums}
"""

${db_bench} \
--benchmarks="readrandomwriterandom" \
--db=${db_dir} \
--wal_dir=${wal_dir} \
--readwritepercent=${rw_percent} \
--num=${op_nums} \
--duration=${time_execute} \
--write_buffer_size=${memtable_size} \
--max_write_buffer_number=${memtable_nums} \
--num_column_families=${cf_nums} \
--report_interval_seconds=${report_duration} \
--report_file=${report_file} \
--threads=${thread_nums} \
--max_background_compactions=${thread_compaction_nums} \
--max_background_flushes=${thread_flush_nums} \

echo "读写性能测试完毕"
