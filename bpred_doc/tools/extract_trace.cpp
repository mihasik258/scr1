// Extract (PC, taken) per conditional branch from a CBP-NG trace, for our bpsim.
#include "trace_reader.hpp"
#include <cstdio>
int main(int argc, char** argv){
    if(argc<2){fprintf(stderr,"usage: %s trace.gz\n",argv[0]);return 2;}
    trace_reader reader(argv[1], "x");
    try{
        for(;;){
            auto inst = reader.next_instruction();
            if(inst.inst_class == INST_CLASS::BR_COND)
                printf("%08x %d\n",(unsigned)(inst.pc & 0xffffffffu), inst.taken_branch?1:0);
        }
    }catch(out_of_instructions&){}
    return 0;
}
