# Module 00: The Terminal

You will learn how to open a terminal on Ubuntu, type commands, and navigate
the filesystem. This is the foundation for everything that follows — every
script in the Attested Agent Authority project runs from the terminal, and
every build step is a command you type (or a script that types many commands
for you).

## Prerequisites

None. This is the first module.

## What you will need

- A computer running Ubuntu 22.04 or 24.04 (a fresh install is fine).

## Concepts

### What is a terminal?

A terminal is a program that lets you talk to your computer by typing text
commands instead of clicking on icons. You type a command, press Enter, and
the computer runs it and prints the result as text. That cycle — type, Enter,
read the output — is the entire interaction model.

On Ubuntu, the terminal program is called **Terminal** (or **GNOME Terminal**
in some versions). You can open it in two ways:

- Press `Ctrl` + `Alt` + `T` on your keyboard (the fastest way).
- Click the grid of dots at the bottom-left of your screen (the "Activities"
  button), type "Terminal", and click the icon that appears.

When the terminal opens, you see a window with a blinking cursor. That
cursor is sitting at the end of a line called the **prompt**. The prompt
usually looks something like this:

```
yourname@yourmachine:~$
```

This tells you: you are logged in as `yourname`, on a machine called
`yourmachine`, and you are currently in the directory called `~` (which is
shorthand for your home directory — more on that in a moment). The `$` at the
end means "I am ready for a command." You do not type the `$` — it is part of
the prompt, not part of your command.

### The filesystem is a tree

Your computer stores files in a tree structure. At the very top is a single
directory called `/` (pronounced "root" or "slash"). Inside it are
directories like `/home`, `/etc`, and `/usr`. Inside `/home` is a directory
with your username, like `/home/yourname`. That is your **home directory** —
the place where your personal files live.

When you open a terminal, you start in your home directory. The `~` in the
prompt is shorthand for it.

### Your first commands

Here are the commands you will use in this module. Each one is a small
program that does one thing:

- **`pwd`** — "print working directory." Shows you where you are in the
  filesystem right now.
- **`ls`** — "list." Shows you the files and directories in your current
  location.
- **`cd`** — "change directory." Moves you to a different directory.
- **`mkdir`** — "make directory." Creates a new directory.
- **`echo`** — Prints text to the screen (and, with a trick, into files).
- **`cat`** — "concatenate." Reads a file and prints its contents to the
  screen.

### Tab completion

You do not have to type every character of every name. If you start typing a
file or directory name and press the `Tab` key, the terminal will try to
finish the name for you. If there is only one possible match, it fills in the
rest. If there are several matches, pressing `Tab` twice shows you all the
possibilities. This saves an enormous amount of typing and prevents typos.

### Getting help

Almost every command has built-in documentation. Two ways to access it:

- **`--help`** — Most commands accept a `--help` flag that prints a short
  summary of what the command does and what options it accepts. For example:
  `ls --help`.
- **`man`** — The `man` command opens the full manual page for any command.
  For example: `man ls`. Manual pages can be long. Press the up and down
  arrow keys to scroll, or press `q` to quit and return to the prompt.

### Error messages

When you make a mistake — misspell a command, try to open a file that does
not exist, forget a required piece — the terminal prints an error message.
Error messages are not punishment; they are the computer telling you what
went wrong. Read them. They almost always name the problem.

For example, if you type `lss` instead of `ls`, you will see something like:

```
Command 'lss' not found
```

That tells you exactly what happened: the computer looked for a program
called `lss`, did not find one, and told you so.

## Exercises

### Exercise 1: Open the terminal and find out where you are

Open a terminal window using `Ctrl` + `Alt` + `T`.

Type the following command and press Enter:

```
pwd
```

**Expected output:**

```
/home/yourname
```

(Where `yourname` is your actual username on this machine.)

**What just happened:** `pwd` printed the full path of your current working
directory. You are in your home directory, which is where the terminal always
starts.

### Exercise 2: Look around

Type the following command and press Enter:

```
ls
```

**Expected output:** A list of files and directories in your home directory.
On a fresh Ubuntu install, you will see names like `Desktop`, `Documents`,
`Downloads`, `Music`, `Pictures`, `Videos`. If your machine has been used
before, you may see more.

**What just happened:** `ls` listed the contents of your current directory.
These are the same folders you would see if you opened the graphical file
manager.

Now try listing with more detail:

```
ls -l
```

**Expected output:** The same names, but now each one has a line of extra
information in front of it — permissions, owner, size, and date. You will
learn what each column means in Module 01. For now, just notice that adding
`-l` changed what `ls` showed you. The `-l` is called a **flag** or
**option** — it modifies the command's behaviour.

### Exercise 3: Create a directory

Create a new directory called `linux-labs`:

```
mkdir linux-labs
```

**Expected output:** Nothing. The terminal prints nothing when a command
succeeds silently. This is normal — silence means success.

Verify the directory was created:

```
ls
```

**Expected output:** Your previous list, plus `linux-labs`.

### Exercise 4: Move into the directory

Change into the directory you just created:

```
cd linux-labs
```

**Expected output:** Nothing printed, but look at your prompt. It should
now show `linux-labs` instead of `~`:

```
yourname@yourmachine:~/linux-labs$
```

Confirm with `pwd`:

```
pwd
```

**Expected output:**

```
/home/yourname/linux-labs
```

**What just happened:** `cd` moved you into the `linux-labs` directory. Your
prompt updated to reflect your new location, and `pwd` confirms it.

### Exercise 5: Create a file with echo

The `echo` command prints text. Combined with `>`, it can write that text
into a file. The `>` symbol means "send the output to this file instead of
the screen."

```
echo "Hello from the terminal" > greeting.txt
```

**Expected output:** Nothing (the output went to the file, not the screen).

Verify the file was created:

```
ls
```

**Expected output:**

```
greeting.txt
```

### Exercise 6: Read a file with cat

Read the file you just created:

```
cat greeting.txt
```

**Expected output:**

```
Hello from the terminal
```

**What just happened:** `cat` read the contents of `greeting.txt` and
printed them to the screen. The file contains exactly the text you wrote
with `echo`.

### Exercise 7: Create a deeper structure

Create a directory inside your current directory, move into it, and create
another file:

```
mkdir notes
cd notes
echo "This is a note inside a subdirectory" > note.txt
cat note.txt
```

**Expected output** (from the `cat` command):

```
This is a note inside a subdirectory
```

Now go back up one level. The special name `..` means "the directory above
this one":

```
cd ..
pwd
```

**Expected output:**

```
/home/yourname/linux-labs
```

**What just happened:** `..` is how you refer to the parent directory. You
went into `notes`, created a file, and then came back up to `linux-labs`.

### Exercise 8: Use tab completion

Start typing a command and let the terminal finish it for you. Type the
following but do NOT press Enter — press `Tab` after typing `gre`:

```
cat gre
```

After pressing `Tab`, the terminal should complete this to:

```
cat greeting.txt
```

Now press Enter to run it.

**Expected output:**

```
Hello from the terminal
```

**What just happened:** Tab completion recognized that `greeting.txt` was
the only file in this directory starting with `gre` and filled in the rest.

### Exercise 9: Try the help system

Look at the help for the `ls` command:

```
ls --help
```

**Expected output:** A long list of options that `ls` accepts. You do not
need to read all of it — the point is knowing it exists. Press `q` if the
output is long enough to fill the screen (it may not be, depending on your
terminal size).

Now try a manual page:

```
man ls
```

**Expected output:** A formatted manual page with sections like NAME,
SYNOPSIS, DESCRIPTION. Use the arrow keys to scroll. Press `q` to quit.

**What just happened:** `--help` gives a quick reference. `man` gives the
full manual. Both exist for almost every command you will encounter.

### Exercise 10: Read an error message

Try to change into a directory that does not exist:

```
cd nonexistent-directory
```

**Expected output:**

```
bash: cd: nonexistent-directory: No such file or directory
```

**What just happened:** The error message tells you three things: which
program reported the problem (`bash`), which command failed (`cd`), and what
went wrong (`No such file or directory`). Every error message follows this
pattern. Read them — they are almost always right.

## Checkpoint

Run the following commands to verify you completed the module. You should
be in your `linux-labs` directory. If you are not, navigate there first
with `cd ~/linux-labs`.

```
pwd
```

Expected output:

```
/home/yourname/linux-labs
```

```
cat greeting.txt
```

Expected output:

```
Hello from the terminal
```

```
cat notes/note.txt
```

Expected output:

```
This is a note inside a subdirectory
```

If all three commands produce the expected output, you have completed
this module.

## Key Takeaways

- The terminal is a text interface for running commands. Type a command,
  press Enter, read the output.
- `pwd` shows where you are. `ls` shows what is here. `cd` moves you.
  `mkdir` creates directories. `echo` prints text (and writes files with
  `>`). `cat` reads files.
- Tab completion saves typing and prevents mistakes.
- `--help` and `man` tell you how any command works.
- Error messages are information, not punishment. Read them.

## How this connects to the project

Every script in the Attested Agent Authority project runs from the terminal.
The build sequence (`make build`) launches ten shell scripts in order, each
one printing progress as text. The demonstration (`make demo`) narrates its
eight acts to the terminal. When something breaks, `make doctor` prints a
diagnostic report as text. The scripts also reach into virtual machines
using terminal commands (`lxc exec`) — they type commands on remote machines
the same way you just typed commands on your own.

The entire workflow of the project — building, running, diagnosing, tearing
down — happens through the same type, Enter, read-output cycle you just
practiced.

## Next

[Module 01: Files, Users, Permissions](../01-files-users-permissions/README.md)
