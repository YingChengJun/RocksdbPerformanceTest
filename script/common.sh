# path
db_dir="../db"
wal_dir="../db"
db_bench="../db_bench"
report_file="../reports/report.csv"

# Default
rw_percent=95
key_nums=1280000
time_execute=1800

# Column Family
cf_nums=1

# Memtable
memtable_size=$((128*1024*1024))
memtable_nums=512
min_write_buffer_number_to_merge=256
compaction_threshold=2
db_write_buffer_size=$((128*1024*1024*1024))

# Thread
thread_nums=8
thread_compaction_nums=1
thread_flush_nums=1

# Report
report_duration=1