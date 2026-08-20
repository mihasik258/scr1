/* bpsim: offline branch-DIRECTION predictor reference model (SCR1 Stage-2).
 * Reads a trace ("hexPC taken" per conditional branch), reports mispredicts for
 * a set of direction predictors so we can compare algorithms and find the
 * accuracy ceiling. bimodal-2b-1024 = SCR1's actual BHT. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define S10 1024u
#define M10 (S10-1)
#define SBIG (1u<<16)          /* 64K-entry "capacity ceiling" table */
#define MBIG (SBIG-1)

static uint8_t bim[S10], loc[S10];
static uint16_t lhist[S10];
static uint8_t g[5][S10];       /* gshare 2/4/6/8/10-bit history, 1024-entry */
static uint8_t gbig[SBIG];      /* gshare 16-bit history, 64K-entry */
static const int GW[5]={2,4,6,8,10};

static inline unsigned ix(uint32_t pc){ return (pc>>1)&M10; }

int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: bpsim trace [label]\n");return 2;}
    FILE*f=fopen(argv[1],"r"); if(!f){perror("open");return 2;}
    const char*lab=argc>=3?argv[2]:argv[1];
    for(unsigned i=0;i<S10;i++){bim[i]=loc[i]=1;lhist[i]=0;for(int k=0;k<5;k++)g[k][i]=1;}
    for(unsigned i=0;i<SBIG;i++)gbig[i]=1;
    uint32_t ghr=0; unsigned long n=0,mnt=0,mbim=0,mloc=0,mg[5]={0},mbig=0;
    uint32_t pc; int tk;
    while(fscanf(f,"%x %d",&pc,&tk)==2){
        n++;
        if(tk)mnt++;
        {unsigned i=ix(pc);int p=bim[i]>>1;if(p!=tk)mbim++;if(tk){if(bim[i]<3)bim[i]++;}else if(bim[i])bim[i]--;}
        for(int k=0;k<5;k++){unsigned i=(ix(pc)^(ghr&((1u<<GW[k])-1)))&M10;int p=g[k][i]>>1;if(p!=tk)mg[k]++;if(tk){if(g[k][i]<3)g[k][i]++;}else if(g[k][i])g[k][i]--;}
        {unsigned i=(ix(pc)^(ghr&0xffff))&MBIG;int p=gbig[i]>>1;if(p!=tk)mbig++;if(tk){if(gbig[i]<3)gbig[i]++;}else if(gbig[i])gbig[i]--;}
        {unsigned s=ix(pc);unsigned i=(s^(lhist[s]<<2))&M10;int p=loc[i]>>1;if(p!=tk)mloc++;if(tk){if(loc[i]<3)loc[i]++;}else if(loc[i])loc[i]--;lhist[s]=((lhist[s]<<1)|tk)&0xff;}
        ghr=(ghr<<1)|tk;
    }
    fclose(f);
    /* machine-readable: RESULT label n nt bim g2 g4 g6 g8 g10 gbig loc */
    printf("RESULT %s %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu\n",lab,n,mnt,mbim,
           mg[0],mg[1],mg[2],mg[3],mg[4],mbig,mloc);
    return 0;
}
