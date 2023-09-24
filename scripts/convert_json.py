# Script modified from Carp https://github.com/dede1751/carp
# https://github.com/dede1751/carp/blob/1fe26d7092fdc776226506cd54e0dcebb807861d/src/engine/nnue/convert_json.py

import sys
import json
import struct

FEATURES = 768
HIDDEN = 256
QA = 255
QB = 64
QAB = QA * QB
PARAM_SIZE = 2  # param size in bytes


def write_bytes(array):
    with open("net.nnue", "ab") as file:
        for num in array:
            file.write(struct.pack("<h", num))

        # Pad the array so we get 64B alignment
        overhead = (len(array) * 2) % 64
        if overhead != 0:
            padding = 64 - overhead
            file.write(struct.pack("<" + str(padding) + "x"))


def convert_weight(json_weight, stride, length, q, transpose):
    weights = [0 for _ in range(length)]

    for i, row in enumerate(json_weight):
        for j, weight in enumerate(row):
            if transpose:
                index = j * stride + i
            else:
                index = i * stride + j

            weights[index] = int(weight * q)

    return weights


def convert_bias(json_bias, q):
    biases = []

    for bias in json_bias:
        value = int(bias * q)
        biases.append(value)

    return biases


# Check for correct number of command line arguments
if len(sys.argv) != 2:
    print("Usage: python convert_json.py <json_file>")
    sys.exit(1)

json_file = sys.argv[1]
with open(json_file, "r") as file:
    data = json.load(file)

feature_weights = convert_weight(
    data["perspective.weight"], HIDDEN, HIDDEN * FEATURES, QA, True
)
feature_biases = convert_bias(data["perspective.bias"], QA)
output_weights = convert_weight(
    data["out.weight"], HIDDEN * 2, HIDDEN * 2, QB, False)
output_biases = convert_bias(data["out.bias"], QAB)

# Clear the old net and write the new data (ordering is important!)
open("net.nnue", "w").close()
write_bytes(feature_weights)
write_bytes(feature_biases)
write_bytes(output_weights)
write_bytes(output_biases)
