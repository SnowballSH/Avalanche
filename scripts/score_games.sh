(trap 'kill 0' SIGINT; \
python3 ./score_games.py ./games/t1 ./t1.txt & \
python3 ./score_games.py ./games/t2 ./t2.txt & \
python3 ./score_games.py ./games/t3 ./t3.txt & \
python3 ./score_games.py ./games/t4 ./t4.txt & \
python3 ./score_games.py ./games/t5 ./t5.txt & \
wait)