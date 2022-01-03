source common.sh
key_nums=10240000
time_execute=0
compaction_threshold=1

# for ((i=8;i<=512;i*=2));
for ((i=1024;i<=1024;i*=2));
do
    # ../old/db_bench_bp_o$i \
    ../db_bench_bp_o$i \
    --benchmarks="fillrandom,readrandom" \
    --reads="81920000" \
    --db=${db_dir} \
    --wal_dir=${wal_dir} \
    --num=${key_nums} \
    --duration=${time_execute} \
    --write_buffer_size=$((4096*1024*1024)) \
    --max_write_buffer_number=512 \
    --num_column_families=1 \
    --report_interval_seconds=1 \
    --report_file=../reports/$i.csv \
    --threads=8 \
    --max_background_compactions=1 \
    --max_background_flushes=1 \
    --min_write_buffer_number_to_merge=256 \
    --db_write_buffer_size=$((128*1024*1024*1024)) \
    --disable_wal=true \
    --compaction_threshold=${compaction_threshold}
done

