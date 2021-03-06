source "./common.sh"

echo "开始测试读写性能"


readwrite_percent=$1
duration=20
num=1000000

${db_bench} \
--benchmarks="readrandomwriterandom" \
--db=${db_dir} \
--wal_dir=${wal_dir} \
--readwritepercent=${readwrite_percent} \
--num=${num} \
--duration=${duration} \

echo "读写性能测试完毕"
