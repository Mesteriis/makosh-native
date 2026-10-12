#ifndef MAKOSH_JPEG_FAULT_FIXTURE_H
#define MAKOSH_JPEG_FAULT_FIXTURE_H
/* Zero means encoding/failure returned safely, without leaked or double-freed output. */
int makosh_jpeg_fault_case(unsigned fail_at);
#endif
