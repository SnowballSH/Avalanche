#!/bin/bash

success=false
attempt_num=1

while [ $success = false ]; do
  ./zig-out/bin/Avalanche datagen_single

  if [ $? -eq 0 ]; then
    success=true
  else
    echo "Attempt $attempt_num failed. Trying again..."
    sleep 2
    attempt_num=$(( attempt_num + 1 ))
  fi
done
