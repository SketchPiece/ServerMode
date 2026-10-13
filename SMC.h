// The AppleSMC user client's call structure, as used by every SMC reading tool.
// Reading keys needs no privileges; this app only reads.

#import <Foundation/Foundation.h>

typedef struct {
    char major, minor, build, reserved;
    UInt16 release;
} SMCVersion;

typedef struct {
    UInt16 version, length;
    UInt32 cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    UInt32 dataSize, dataType;
    char dataAttributes;
} SMCKeyInfo;

typedef struct {
    UInt32 key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCParam;
