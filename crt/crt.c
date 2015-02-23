#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <inttypes.h>
#include <sys/time.h>

#define RETC_PRINT_USAGE     1
#define RETC_PRINT_INFO      2

#define OUTBUFFER_SIZE       (16*1024)
#define INBUFFER_SIZE        (16*1024)
#define INITIAL_BUFFER_SIZE  (4096*8)
#define INLINE static inline

typedef %%BUFFER_UNIT_T buffer_unit_t;
typedef struct {
  buffer_unit_t *data;
  size_t size;         /* size in bytes */
  size_t bitpos;       /* size in bits  */
} buffer_t;

#define BUFFER_UNIT_SIZE (sizeof(buffer_unit_t))
#define BUFFER_UNIT_BITS (BUFFER_UNIT_SIZE * 8)

char *next;
buffer_t outbuf;
size_t count = 0;

char inbuf[INBUFFER_SIZE*2];
size_t in_size = 0;
int in_cursor = 0;
#define avail (in_size - in_cursor)

void buf_flush(buffer_t *buf)
{
  size_t word_index = buf->bitpos / BUFFER_UNIT_BITS;
  // If we do not have a single complete word to flush, return.
  // Not just an optimization! The zeroing logic below assumes word_index > 0.
  if (word_index == 0)
  {
    return;
  }
  if (fwrite(buf->data, BUFFER_UNIT_SIZE, word_index, stdout) == -1)
  {
    fprintf(stderr, "Error writing to stdout.\n");
    exit(1);
  }
  // Zeroing is important, as we "or" bit fragments into buffer.
  memset(buf->data, 0, word_index * BUFFER_UNIT_SIZE);
  // Since partially written words are not flushed, they need to be moved to the
  // beginning of the buffer.
  // Note: We assume word_index > 0 to avoid losing data!
  buf->data[0] = buf->data[word_index];
  // ... and then zeroed
  buf->data[word_index] = 0;

  // Rewind cursor
  buf->bitpos = buf->bitpos - word_index * BUFFER_UNIT_BITS;
}

// Write first 'bits' of 'w' to 'buf', starting from the MOST significant bit.
// Precondition: Remaining bits of 'w' must be zero.
INLINE
bool buf_writeconst(buffer_t *buf, buffer_unit_t w, int bits)
{
  size_t word_index = buf->bitpos / BUFFER_UNIT_BITS;
  size_t offset = buf->bitpos % BUFFER_UNIT_BITS;
  size_t bits_available = BUFFER_UNIT_BITS - offset;

  buf->data[word_index] |= w >> offset;
  // Test important; shifting by the word size is undefined behaviour.
  if (offset > 0)
  {
    buf->data[word_index+1] |= w << bits_available;
  }

  buf->bitpos += bits;

  // Is cursor in last word?
  return (buf->bitpos >= buf->size * 8 - BUFFER_UNIT_BITS);
}

void buf_resize(buffer_t *buf, size_t shift)
{
  size_t new_size = buf->size << shift;
  buffer_unit_t *data2 = malloc(new_size);
  memset(data2, 0, new_size);
  memcpy(data2, buf->data, buf->size);
  free(buf->data);
  buf->data = data2;
  buf->size = new_size;
}

INLINE
void buf_writearray(buffer_t *dst, const buffer_unit_t *arr, int bits)
{
  if (dst->bitpos % BUFFER_UNIT_BITS == 0)
  {
    int count = (bits / BUFFER_UNIT_BITS) + (bits % BUFFER_UNIT_BITS ? 1 : 0);
    memcpy(&dst->data[dst->bitpos / BUFFER_UNIT_BITS], arr, count * BUFFER_UNIT_SIZE);
    dst->bitpos += bits;
  } else
  {
    int word_index = 0;
    for (word_index = 0; word_index <= bits / BUFFER_UNIT_BITS; word_index++)
    {
      buf_writeconst(dst, arr[word_index], BUFFER_UNIT_BITS);
    }

    if (bits % BUFFER_UNIT_BITS != 0)
    {
      buf_writeconst(dst, arr[word_index], bits % BUFFER_UNIT_BITS);
    }
  }
}

INLINE
void reset(buffer_t *buf)
{
  memset(buf->data, 0, buf->bitpos / 8);
  if (buf->bitpos % BUFFER_UNIT_BITS != 0)
  {
    buf->data[buf->bitpos / BUFFER_UNIT_BITS] = 0;
  }
  buf->bitpos = 0;
}

void init_buffer(buffer_t *buf)
{
  buf->data = malloc(INITIAL_BUFFER_SIZE);
  buf->size = INITIAL_BUFFER_SIZE;
  buf->bitpos = 0;
  memset(buf->data, 0, buf->size);
}

INLINE
void outputconst(buffer_unit_t w, int bits)
{
  if (buf_writeconst(&outbuf, w, bits))
  {
    buf_flush(&outbuf);
  }
}

INLINE
void appendarray(buffer_t *dst, const buffer_unit_t *arr, int bits)
{
  size_t total_bits = dst->bitpos + bits;
  if (total_bits >= (dst->size - 1) * BUFFER_UNIT_BITS * BUFFER_UNIT_SIZE)
  {
    size_t shift = 1;
    while (total_bits >= ((dst->size << shift) - 1) * BUFFER_UNIT_BITS * BUFFER_UNIT_SIZE)
    {
      shift++;  
    }
    buf_resize(dst, shift);
  }

  buf_writearray(dst, arr, bits);
}

INLINE
void append(buffer_t *buf, buffer_unit_t w, int bits)
{
  if (buf_writeconst(buf, w, bits))
  {
    buf_resize(buf, 1);
  }  
}

INLINE
void concat(buffer_t *dst, buffer_t *src)
{
  appendarray(dst, src->data, src->bitpos);
}

INLINE
void outputarray(const buffer_unit_t *arr, int bits)
{
 if (outbuf.bitpos % BUFFER_UNIT_BITS == 0)
 {
   buf_flush(&outbuf);
   int word_count = bits / BUFFER_UNIT_BITS;
   if (word_count == 0)
   {
     return;
   }
   if (fwrite(arr, BUFFER_UNIT_SIZE, word_count, stdout) == -1)
//   if (write(fileno(stdout), arr, word_count * BUFFER_UNIT_SIZE) == -1)
   {
     fprintf(stderr, "Error writing to stdout.\n");
     exit(1);
   }
 }
 else
 {
    // Write completed words
    size_t word_index = 0;
    for (word_index = 0; word_index < bits / BUFFER_UNIT_BITS; word_index++)
    {
      outputconst(arr[word_index], BUFFER_UNIT_BITS);
    }
 }

  int remaining = bits % BUFFER_UNIT_BITS;
  if (remaining != 0)
  {
    outputconst(arr[bits / BUFFER_UNIT_BITS], remaining);
  }
}

INLINE
void output(buffer_t *buf)
{
  if (outbuf.bitpos % BUFFER_UNIT_BITS == 0)
  {
    buf_flush(&outbuf);
    buf_flush(buf);
    // Important that we fall through to the "handle remaining bits" case.
  }

  // Write completed words
  size_t word_index = 0;
  for (word_index = 0; word_index < buf->bitpos / BUFFER_UNIT_BITS; word_index++)
  {
    outputconst(buf->data[word_index], BUFFER_UNIT_BITS);
  }

  // Handle remaining bits
  if (buf->bitpos % BUFFER_UNIT_BITS != 0)
  {
    size_t remaining = buf->bitpos - (word_index * BUFFER_UNIT_BITS);
    outputconst(buf->data[word_index], remaining);
  }
}

INLINE
void consume(int c)
{
  count     += c;
  in_cursor += c;
  next      += c;
}

INLINE
int readnext(int minCount, int maxCount)
{
  if (avail < maxCount)
  {
    int remaining = avail;
    memmove(&inbuf[INBUFFER_SIZE - remaining], &inbuf[INBUFFER_SIZE+in_cursor], remaining);
    in_cursor = -remaining;
    in_size = fread(&inbuf[INBUFFER_SIZE], 1, INBUFFER_SIZE, stdin);
  }
  if (avail < minCount)
  {
    return 0;
  }
  next = &inbuf[INBUFFER_SIZE+in_cursor];
  return 1;
}

INLINE
int cmp(char *str1, char *str2, int l)
{
  int i = 0;
  for (i = 0; i < l; i++)
  {
    if (str1[i] != str2[i])
      return 0;
  }
  return 1;
}

%%TABLES

%%DECLS

void match()
{
%%PROG
  accept:
    return;

  fail:
    fprintf(stderr, "Match error at input symbol %zu!\n", count);
    exit(1);
}

void printCompilationInfo()
{
  fprintf(stdout,
%%COMP_INFO
          );
}

void printUsage(char *name)
{
  fprintf(stdout, "Normal usage: %s < infile > outfile\n", name);
  fprintf(stdout, "- \"%s\": reads from stdin and writes to stdout.\n", name);
  fprintf(stdout, "- \"%s -i\": prints compilation info.\n", name);
  fprintf(stdout, "- \"%s -t\": runs normally, but prints timing to stderr.\n", name);
}

void run()
{
  match();
  if (outbuf.bitpos % BUFFER_UNIT_BITS != 0)
  {
    outputconst(0, BUFFER_UNIT_BITS);
  }
  buf_flush(&outbuf);
}

int main(int argc, char *argv[])
{
  bool do_timing = false;

  if(argc > 2)
  {
    printUsage(argv[0]);
    return RETC_PRINT_USAGE;
  }
  if (argc == 2) 
  {
    if(strcmp("-i", argv[1]) == 0)
    {
      printCompilationInfo();
      return RETC_PRINT_INFO;
    }
    else if(strcmp("-t", argv[1]) == 0)
    {
      do_timing = true;
    }
    else
    {
      printUsage(argv[0]);
      return RETC_PRINT_USAGE;
    }
  }
    
  outbuf.size = OUTBUFFER_SIZE + BUFFER_UNIT_SIZE;
  outbuf.data = malloc(outbuf.size);
  reset(&outbuf);

%%INIT

  if(do_timing)
  {
    struct timeval time_before, time_after, time_result;
    long int millis;
    gettimeofday(&time_before, NULL);
    run();
    gettimeofday(&time_after, NULL);
    timersub(&time_after, &time_before, &time_result);
    // A timeval contains seconds and microseconds.
    millis = time_result.tv_sec * 1000 + time_result.tv_usec / 1000;
    fprintf(stderr, "time (ms): %ld\n", millis);
  }
  else
  {
    run();
  }

  return 0;
}
