#!/bin/bash

parallel -X --ungroup -j 7 bash ./gen.sh ::: {1..7}