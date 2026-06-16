#!/bin/bash
# runs for 1100 mins
# these are parallel
# Sleep 2s between spawns so each process gets a unique timestamp-based filename.

./scripts/datagen.sh 11 1100 &
sleep 2
./scripts/datagen.sh 11 1100 &
sleep 2
./scripts/datagen.sh 10 1100 &
sleep 2
./scripts/datagen.sh 11 1100 books/noob_4moves.epd &
sleep 2
./scripts/datagen.sh 11 1100 books/noob_4moves.epd &
sleep 2
./scripts/datagen.sh 10 1100 books/UHO_4060_v4.epd &
sleep 2
./scripts/datagen.sh 10 1100 books/UHO_4060_v4.epd &
sleep 2
./scripts/datagen.sh 11 1100 books/UHO_Lichess_4852_v1.epd &
sleep 2
./scripts/datagen.sh 10 1100 books/UHO_Lichess_4852_v1.epd &

wait