# Batch waveform dump: record every signal under the top module into waves.shm, run, exit.
# Used by `make WAVE=1`. Open the result later with `make view` (remote desktop).
database -open waves -shm -into waves.shm -default
probe -create -all -depth all -database waves
run
exit
