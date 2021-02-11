#include "waiter.h"
#include "PL011.h"

#define numberOfForks 16
#define numberOfPhilosophers 16

extern void main_philosopher();

int fds[2];
int pfds[numberOfPhilosophers * 2];
bool allFull;

phil_t phil[numberOfPhilosophers];

void initializePhilosophers()
{
  for (int i = 0; i < numberOfPhilosophers; i++)
  {
    phil[i].forks = 1;
    phil[i].hungry = true;
    if (i == 0)
    {
      phil[i].left = &phil[numberOfPhilosophers - 1];
    }
    else
    {
      phil[i].left = &phil[i - 1];
    }
    if (i == numberOfPhilosophers - 1)
    {
      phil[i].right = &phil[0];
    }
    else
    {
      phil[i].right = &phil[i + 1];
    }
  }
}

void main_waiter()
{
  //initializePhilosophers();

  for (int i = 0; i < numberOfPhilosophers; i++)
  {
    pipe(fds);
    pfds[2 * i] = fds[0];
    pfds[2 * i + 1] = fds[1];
    pid_t pid = fork();
    if (pid == 0)
    {
      exec(&main_philosopher);
    }
  }

  for (int i = 0; i < numberOfPhilosophers / 2; i++)
  {
    writePipe((int)(pfds[4 * i + 1]), -1);
  }
  for (int i = 0; i < numberOfPhilosophers / 2; i++)
  {
    writePipe((int)(pfds[4 * i + 3]), 1);
  }

  for (int i = 0; i < numberOfPhilosophers / 2; i++)
  {
    bool waiting = true;
    while (waiting)
    {
      if (writePipe((int)(pfds[4 * i + 3]), -2) == 0)
      {
        waiting = false;
      }
    }
  }

  for (int i = 0; i < numberOfPhilosophers / 2; i++)
  {
    bool waiting = true;
    while (waiting)
    {
      if (writePipe((int)(pfds[4 * i + 1]), 2) == 0)
      {
        waiting = false;
      }
    }
  }

  for (int i = 0; i < numberOfPhilosophers; i++)
  {
    bool waiting = true;
    while (waiting)
    {
      if (writePipe((int)(pfds[2 * i + 1]), 6) == 0)
      {
        waiting = false;
      }
    }
  }

  exit(EXIT_SUCCESS);
}
