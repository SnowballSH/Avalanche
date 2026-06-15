#!/bin/bash
# runs for 700 mins
# these are parallel

./scripts/datagen.sh 11 700 &
./scripts/datagen.sh 11 700 &
./scripts/datagen.sh 11 700 &
./scripts/datagen.sh 10 700 books/noob_4moves.epd &
./scripts/datagen.sh 10 700 books/noob_4moves.epd &
./scripts/datagen.sh 10 700 books/UHO_4060_v4.epd &
./scripts/datagen.sh 10 700 books/UHO_4060_v4.epd &
./scripts/datagen.sh 10 700 books/UHO_Lichess_4852_v1.epd &
./scripts/datagen.sh 10 700 books/UHO_Lichess_4852_v1.epd &

wait