#include "philosophers.h"
#include "PL011.h"

int fds[2];
int forksAvailable;
bool hungry;

void eat()
{
  hungry = false;
}

void main_philosopher()
{
  forksAvailable = 1;
  hungry = true;

  while (hungry)
  {
    int extraForks = readPipe((int)(fds[0]));
    forksAvailable += extraForks;

    if (forksAvailable == 2)
    {
      eat();
      write(STDOUT_FILENO, "YUM", 3);
    }
  }

  bool done = false;
  while (!done)
  {
    if (readPipe((int)(fds[0])) > 5)
    {
      close((int)(fds[0]));
      done = true;
    }
  }

  exit(EXIT_SUCCESS);
}