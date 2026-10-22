# SA-GEMM UVM runs on Cadence Xcelium. Run from sim/.
#
#   make                                 # csr_reset_test, seed 1 (CSR testbench)
#   make TB=top TEST=gemm_rand_test      # full-chip testbench (files_top.f)
#   make TEST=csr_reset_test SEED=7
#   make VERB=UVM_HIGH                   # more log detail
#   make GUI=1                           # open the run in SimVision (remote desktop only)
#   make WAVE=1                          # batch run that records waves.shm (works over ssh)
#   make view                            # open waves.shm in SimVision (remote desktop only)
#   make TB=top TEST=gemm_rand_test PLUSARGS=+JOBS=40
#   make regress                         # every test x seeds 1..4, in parallel (regress.py)
#   make regress ARGS="--seeds 20 -j 12" # sign-off depth
#   make mutate                          # inject each RTL bug in mutate.py, run its tests
#   make clean

SHELL := /bin/bash

TB    ?= csr                 # which filelist: files_$(TB).f
TEST  ?= csr_reset_test
SEED  ?= 1
VERB  ?= UVM_MEDIUM
GUI   ?= 0
WAVE  ?= 0
PLUSARGS ?=
ARGS  ?=

LOG   := logs/$(TEST)_$(SEED).log
OPTS  := -f xrun.args -f files_$(strip $(TB)).f -svseed $(SEED) \
         +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(PLUSARGS) -l $(LOG)
ifeq ($(GUI),1)
OPTS  += -access +rwc -gui
endif
ifeq ($(WAVE),1)
OPTS  += -input waves.tcl
endif

.PHONY: run view clean regress mutate
run:
	@mkdir -p logs
	@xrun $(OPTS) > /dev/null; \
	grep -E "\*[EF],|UVM_(ERROR|FATAL) .*@|RESULT|UVM_ERROR :|UVM_FATAL :" $(LOG) | grep -v IMPDLL; \
	grep -q "TEST PASSED" $(LOG)

# Plain `simvision` starts a 32-bit binary that cannot run on this server; -64bit is required.
view:
	simvision -64bit waves.shm &

regress:
	python3 regress.py $(ARGS)

mutate:
	python3 mutate.py $(ARGS)

clean:
	rm -rf xcelium.d logs waves.shm .simvision xrun.history xrun.key xrun.log regress mutants
