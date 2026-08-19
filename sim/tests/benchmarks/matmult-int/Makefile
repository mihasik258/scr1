src_dir := $(dir $(lastword $(MAKEFILE_LIST)))
COMMON  := $(src_dir)../embench_common

ADD_FLAGS   := -flto
ADD_LDFLAGS := -flto
ADD_VPATH   := $(COMMON)
ADD_incs    := -I$(COMMON)
ADD_CFLAGS  := -DBENCH_NAME='"matmult-int"' -DWARMUP_HEAT=1 -DGLOBAL_SCALE_FACTOR=1 -DCPU_MHZ=1

c_src := sc_print.c beebsc.c embench_main.c matmult-int.c

include $(inc_dir)/common.mk

default: log_requested_tgt $(bld_dir)/matmult-int.elf $(bld_dir)/matmult-int.hex $(bld_dir)/matmult-int.dump
log_requested_tgt:
	@echo matmult-int.hex>> $(bld_dir)/test_info
clean:
	$(RM) $(c_objs) $(asm_objs) $(bld_dir)/matmult-int.elf $(bld_dir)/matmult-int.hex $(bld_dir)/matmult-int.dump
