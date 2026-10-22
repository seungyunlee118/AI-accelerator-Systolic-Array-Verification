# SA-GEMM UVM runs on Cadence Xcelium. Run from sim/.
#
#   make                                 # csr_reset_test, seed 1
#   make TEST=csr_reset_test SEED=7
#   make VERB=UVM_HIGH                   # more log detail
#   make GUI=1                           # open the run in SimVision
#   make clean

SHELL := /bin/bash

TB    ?= csr                 # which filelist: files_$(TB).f
TEST  ?= csr_reset_test
SEED  ?= 1
VERB  ?= UVM_MEDIUM
GUI   ?= 0

LOG   := logs/$(TEST)_$(SEED).log
OPTS  := -f xrun.args -f files_$(strip $(TB)).f -svseed $(SEED) \
         +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) -l $(LOG)
ifeq ($(GUI),1)
OPTS  += -access +rwc -gui
endif

.PHONY: run clean
run:
	@mkdir -p logs
	@xrun $(OPTS) > /dev/null; \
	grep -E "\*[EF],|UVM_(ERROR|FATAL) .*@|RESULT|UVM_ERROR :|UVM_FATAL :" $(LOG) | grep -v IMPDLL; \
	grep -q "TEST PASSED" $(LOG)

clean:
	rm -rf xcelium.d logs waves.shm .simvision xrun.history xrun.key xrun.log
