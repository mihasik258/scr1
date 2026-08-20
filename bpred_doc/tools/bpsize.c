/* Table-size sweep for bimodal & gshare on a (PC taken) trace. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
static uint32_t *pc_a; static uint8_t *tk_a; static long N;
static void load(const char*f){FILE*p=fopen(f,"r");long cap=1<<20;pc_a=malloc(cap*4);tk_a=malloc(cap);N=0;uint32_t pc;int t;
  while(fscanf(p,"%x %d",&pc,&t)==2){if(N>=cap){cap*=2;pc_a=realloc(pc_a,cap*4);tk_a=realloc(tk_a,cap);}pc_a[N]=pc;tk_a[N]=t;N++;}fclose(p);}
static long bim(unsigned bits){unsigned S=1u<<bits,M=S-1;uint8_t*t=malloc(S);memset(t,1,S);long m=0;
  for(long i=0;i<N;i++){unsigned x=(pc_a[i]>>1)&M;int p=t[x]>>1;if(p!=tk_a[i])m++;if(tk_a[i]){if(t[x]<3)t[x]++;}else if(t[x])t[x]--;}free(t);return m;}
static long gsh(unsigned bits){unsigned S=1u<<bits,M=S-1;uint8_t*t=malloc(S);memset(t,1,S);long m=0;uint32_t g=0;
  for(long i=0;i<N;i++){unsigned x=((pc_a[i]>>1)^(g&M))&M;int p=t[x]>>1;if(p!=tk_a[i])m++;if(tk_a[i]){if(t[x]<3)t[x]++;}else if(t[x])t[x]--;g=(g<<1)|tk_a[i];}free(t);return m;}
int main(int c,char**v){load(v[1]);
  printf("size(2b)  Kbit  bimodal%%  gshare%%\n");
  for(unsigned b=7;b<=20;b++){long mb=bim(b),mg=gsh(b);double kb=(1u<<b)*2/1024.0;
    printf("%7u  %5.1f  %7.3f  %7.3f\n",1u<<b,kb,100.0*(N-mb)/N,100.0*(N-mg)/N);}
  printf("(trace=%s N=%ld)\n",v[1],N);return 0;}
