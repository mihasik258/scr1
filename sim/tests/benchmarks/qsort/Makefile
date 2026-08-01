src_dir := $(dir $(lastword $(MAKEFILE_LIST)))

ADD_FLAGS     := -flto
ADD_LDFLAGS   := -flto

c_src := sc_print.c qsort.c

include $(inc_dir)/common.mk

default: log_requested_tgt $(bld_dir)/qsort.elf $(bld_dir)/qsort.hex $(bld_dir)/qsort.dump

log_requested_tgt:
	@echo qsort.hex>> $(bld_dir)/test_info

clean:
	$(RM) $(c_objs) $(asm_objs) $(bld_dir)/qsort.elf $(bld_dir)/qsort.hex $(bld_dir)/qsort.dump
