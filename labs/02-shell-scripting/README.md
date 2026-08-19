# Module 02: Shell Scripting

You will learn how to write shell scripts — text files full of commands that
run automatically, one after another. This matters for the final project
because the entire build system is a sequence of shell scripts, and every one
of them uses the safety patterns you will learn here: strict error handling,
exit codes, and traps that report the failing line when something goes wrong.

## Prerequisites

- [Module 00: The Terminal](../00-the-terminal/README.md)
- [Module 01: Files, Users, Permissions](../01-files-users-permissions/README.md)

## What you will need

- The same Ubuntu machine from previous modules.

## Concepts

### What is a shell script?

A shell script is a plain text file containing commands — the same commands
you have been typing into the terminal. Instead of typing them one at a time,
you write them all into a file and run the file. The shell (the program that
reads your commands, usually **bash** on Ubuntu) reads the file line by line
and executes each command in order.

This is how automation works on Linux. Anything you can do by hand in the
terminal, you can write into a script and have the computer do repeatedly,
identically, without mistakes.

### The shebang line

The first line of a shell script tells the system which program should
interpret it. It looks like this:

```bash
#!/usr/bin/env bash
```

This line is called the **shebang** (from the `#!` characters). It says:
"find the `bash` program and use it to run this file." The `/usr/bin/env`
part is a portable way to find bash no matter where it is installed.

Every script in the Attested Agent Authority project starts with this line.

### Making a script executable

A script is just a text file. To run it directly (by typing its name rather
than `bash scriptname.sh`), you need to give it execute permission:

```
chmod +x myscript.sh
```

You learned about `chmod` in Module 01. Adding `+x` (which is short for
`a+x`) gives everyone execute permission.

### Variables

A **variable** stores a value that you can use later. You create one by
writing `name=value` (no spaces around the `=`). You read it by putting `$`
in front of the name:

```bash
greeting="Hello, world"
echo "$greeting"
```

The quotes around `$greeting` are important. Without them, if the variable
contains spaces, the shell will split it into separate words and things will
break in subtle ways. The rule: always quote your variables with double
quotes.

### String interpolation

Inside double quotes, variables are expanded (replaced with their values):

```bash
name="Alice"
echo "Hello, $name"     # prints: Hello, Alice
echo "Home is $HOME"    # prints: Home is /home/alice
```

Inside single quotes, nothing is expanded:

```bash
echo 'Hello, $name'     # prints: Hello, $name (literally)
```

### if / then / else / fi

The `if` statement lets a script make decisions:

```bash
if [ -f "config.txt" ]; then
    echo "config.txt exists"
else
    echo "config.txt does not exist"
fi
```

The `[ -f "config.txt" ]` part is a test. `-f` checks whether a file exists
and is a regular file (not a directory). Other useful tests:

- `[ -d "dirname" ]` — true if the directory exists
- `[ -e "path" ]` — true if anything exists at that path
- `[ "$a" = "$b" ]` — true if the two strings are equal
- `[ "$a" != "$b" ]` — true if they differ

The spaces inside the brackets are required — `[-f file]` is a syntax error.

The `fi` at the end is `if` spelled backwards. It marks the end of the if
block.

### Exit codes

Every command that runs produces an **exit code** — a number between 0 and
255. By convention:

- **0** means success.
- **Anything else** means failure.

You can check the exit code of the last command with `$?`:

```bash
ls /etc/passwd
echo $?        # prints 0 (success — the file exists)

ls /nonexistent
echo $?        # prints 2 (failure — file not found)
```

Scripts themselves produce an exit code. You can set it explicitly with the
`exit` command:

```bash
exit 0    # the script succeeded
exit 1    # the script failed
```

### set -euo pipefail

This line appears near the top of every serious shell script. It turns on
three safety features:

- **`-e`** (errexit): If any command fails (returns a non-zero exit code),
  stop the script immediately. Without this, the script would keep going
  after a failure, potentially making things worse.

- **`-u`** (nounset): If the script tries to use a variable that was never
  set, stop immediately with an error. Without this, unset variables silently
  become empty strings, which causes mysterious bugs.

- **`-o pipefail`**: If any command in a pipeline (commands connected with
  `|`) fails, the whole pipeline is considered failed. Without this, only the
  exit code of the last command in the pipe matters, and failures earlier in
  the chain are silently ignored.

Together, these three flags mean: fail loudly and immediately instead of
silently doing the wrong thing.

### Error trapping with trap

The `trap` command lets you run a cleanup command when something goes wrong.
It is like saying "if anything fails, do this before exiting." The most
common use is printing which line failed:

```bash
trap 'echo "Error on line $LINENO"' ERR
```

This tells bash: whenever a command fails (triggers `ERR`), print the line
number where it happened. The project's `scripts/lib/common.sh` does exactly
this — its trap prints the script name and the failing line number, so you
never have to guess where a build step broke.

### Idempotency

A script is **idempotent** if running it twice produces the same result as
running it once. For example, "create directory X if it does not exist" is
idempotent — the first run creates it, the second run sees it already exists
and does nothing. "Create directory X" without the check is not idempotent —
the second run fails because the directory already exists.

Every build script in the Attested Agent Authority project is idempotent.
This is why `make build` is safe to re-run: finished steps detect they are
already done and skip themselves.

## Exercises

### Exercise 1: Write and run your first script

Navigate to your lab directory and create a script:

```
cd ~/linux-labs
```

Create the script file with these contents. Type each line into the terminal
exactly as shown:

```
cat > hello.sh << 'SCRIPT'
#!/usr/bin/env bash
echo "Hello from a shell script"
echo "Today is $(date)"
echo "You are $(whoami)"
SCRIPT
```

The `cat > hello.sh << 'SCRIPT'` construction writes everything between the
first `SCRIPT` and the last `SCRIPT` into the file `hello.sh`. This is called
a **here-document** and it is a convenient way to write multi-line files from
the terminal.

Look at the file:

```
cat hello.sh
```

**Expected output:**

```
#!/usr/bin/env bash
echo "Hello from a shell script"
echo "Today is $(date)"
echo "You are $(whoami)"
```

Make it executable and run it:

```
chmod +x hello.sh
./hello.sh
```

**Expected output:**

```
Hello from a shell script
Today is Wed Aug 10 14:00:00 UTC 2025
You are alice
```

(Your date and username will differ.)

**What just happened:** You wrote a text file containing three commands, made
it executable with `chmod +x`, and ran it with `./hello.sh`. The `./` means
"run the file in the current directory" — without it, the shell looks for a
program called `hello.sh` in system directories and will not find it.

### Exercise 2: Variables and string interpolation

Create a script that uses variables:

```
cat > greet.sh << 'SCRIPT'
#!/usr/bin/env bash
target="world"
echo "Hello, $target"
echo "Your home directory is $HOME"
echo 'This line uses single quotes: $target is not expanded'
SCRIPT

chmod +x greet.sh
./greet.sh
```

**Expected output:**

```
Hello, world
Your home directory is /home/alice
This line uses single quotes: $target is not expanded
```

**What just happened:** The variable `target` was set and then used with
`$target`. Inside double quotes, it was replaced with its value. Inside
single quotes, it was printed literally. `$HOME` is a variable the system
sets for you automatically — it contains your home directory path.

### Exercise 3: Using if/then/else

Create a script that checks whether a file exists:

```
cat > check-file.sh << 'SCRIPT'
#!/usr/bin/env bash
filename="testfile.txt"

if [ -f "$filename" ]; then
    echo "$filename exists"
    echo "Contents:"
    cat "$filename"
else
    echo "$filename does not exist, creating it"
    echo "Created by check-file.sh on $(date)" > "$filename"
    echo "Created $filename"
fi
SCRIPT

chmod +x check-file.sh
```

Run it twice:

```
./check-file.sh
```

**Expected output (first run):**

```
testfile.txt does not exist, creating it
Created testfile.txt
```

```
./check-file.sh
```

**Expected output (second run):**

```
testfile.txt exists
Contents:
Created by check-file.sh on Wed Aug 10 14:05:00 UTC 2025
```

**What just happened:** The first run took the `else` branch and created the
file. The second run took the `if` branch because the file now existed. The
script behaved differently based on the state of the filesystem. This is
**idempotent** behaviour — the script checks before acting, so running it
again does not create a duplicate or fail.

### Exercise 4: Exit codes

Observe exit codes in action:

```
ls /etc/passwd
echo "Exit code: $?"
```

**Expected output:**

```
/etc/passwd
Exit code: 0
```

```
ls /nonexistent-file-12345
echo "Exit code: $?"
```

**Expected output:**

```
ls: cannot access '/nonexistent-file-12345': No such file or directory
Exit code: 2
```

Now create a script that uses exit codes:

```
cat > exit-demo.sh << 'SCRIPT'
#!/usr/bin/env bash
if [ -f "/etc/passwd" ]; then
    echo "System looks healthy"
    exit 0
else
    echo "Something is very wrong"
    exit 1
fi
SCRIPT

chmod +x exit-demo.sh
./exit-demo.sh
echo "Script exited with: $?"
```

**Expected output:**

```
System looks healthy
Script exited with: 0
```

**What just happened:** The script checked a condition and explicitly chose
its exit code. Other scripts (or the terminal) can check this exit code to
decide what to do next. The entire build system depends on this: if any build
step exits non-zero, the build stops.

### Exercise 5: set -euo pipefail in action

Create a script without the safety flags:

```
cat > unsafe.sh << 'SCRIPT'
#!/usr/bin/env bash
echo "Step 1: starting"
ls /nonexistent-path-12345
echo "Step 2: this should not run after a failure, but it does"
echo "Step 3: the script kept going after an error"
SCRIPT

chmod +x unsafe.sh
./unsafe.sh
```

**Expected output:**

```
Step 1: starting
ls: cannot access '/nonexistent-path-12345': No such file or directory
Step 2: this should not run after a failure, but it does
Step 3: the script kept going after an error
```

Now add the safety flags:

```
cat > safe.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "Step 1: starting"
ls /nonexistent-path-12345
echo "Step 2: this line will never run"
SCRIPT

chmod +x safe.sh
./safe.sh
```

**Expected output:**

```
Step 1: starting
ls: cannot access '/nonexistent-path-12345': No such file or directory
```

The script stopped at the failing command. Step 2 never ran.

Check the exit code:

```
echo "Exit code: $?"
```

**Expected output:**

```
Exit code: 2
```

**What just happened:** Without `set -euo pipefail`, a failing command prints
an error but the script keeps running — potentially doing damage with
incorrect assumptions. With the flags, the script stops immediately at the
first failure. This is why every script in the project uses these flags.

### Exercise 6: The nounset flag (-u)

See what happens when you use an undefined variable:

```
cat > unset-demo.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "The value is: $UNDEFINED_VARIABLE"
echo "This line will never run"
SCRIPT

chmod +x unset-demo.sh
./unset-demo.sh
```

**Expected output:**

```
./unset-demo.sh: line 4: UNDEFINED_VARIABLE: unbound variable
```

**What just happened:** The `-u` flag caught the use of a variable that was
never set. Without `-u`, `$UNDEFINED_VARIABLE` would silently become an empty
string, and the script would print "The value is: " and keep going — which
could lead to commands running with missing arguments. The error message tells
you exactly which variable and which line.

### Exercise 7: Error trapping

Create a script with a trap:

```
cat > trapped.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

trap 'echo "TRAP: Error on line $LINENO (exit code $?)"' ERR

echo "Line 6: this works"
echo "Line 7: this also works"
ls /nonexistent-path-12345
echo "Line 9: this never runs"
SCRIPT

chmod +x trapped.sh
./trapped.sh
```

**Expected output:**

```
Line 6: this works
Line 7: this also works
ls: cannot access '/nonexistent-path-12345': No such file or directory
TRAP: Error on line 8 (exit code 2)
```

**What just happened:** When `ls` failed on line 8, the `set -e` flag would
normally just stop the script. The `trap` intercepted the error and printed
the line number and exit code before the script stopped. This is exactly how
the project's `scripts/lib/common.sh` works — its trap function
(`_aaa_trap`) prints the script name and line number whenever a build step
fails, so you never have to guess which command broke.

### Exercise 8: An idempotent setup script

Write a script that sets up a directory structure, and prove it is safe to
run twice:

```
cat > setup.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"' ERR

project_dir="$HOME/linux-labs/my-project"

# Create the directory if it does not exist
if [ -d "$project_dir" ]; then
    echo "Directory already exists: $project_dir"
else
    mkdir -p "$project_dir"
    echo "Created directory: $project_dir"
fi

# Create a config file if it does not exist
config="$project_dir/config.txt"
if [ -f "$config" ]; then
    echo "Config already exists: $config"
else
    echo "version=1.0" > "$config"
    echo "Created config: $config"
fi

# Report the result
echo "Setup complete. Contents of $project_dir:"
ls -la "$project_dir"
SCRIPT

chmod +x setup.sh
```

Run it twice:

```
./setup.sh
```

**Expected output (first run):**

```
Created directory: /home/alice/linux-labs/my-project
Created config: /home/alice/linux-labs/my-project/config.txt
Setup complete. Contents of /home/alice/linux-labs/my-project:
total 12
drwxrwxr-x 2 alice alice 4096 Aug 10 14:30 .
drwxrwxr-x 5 alice alice 4096 Aug 10 14:30 ..
-rw-rw-r-- 1 alice alice   12 Aug 10 14:30 config.txt
```

```
./setup.sh
```

**Expected output (second run):**

```
Directory already exists: /home/alice/linux-labs/my-project
Config already exists: /home/alice/linux-labs/my-project/config.txt
Setup complete. Contents of /home/alice/linux-labs/my-project:
total 12
drwxrwxr-x 2 alice alice 4096 Aug 10 14:30 .
drwxrwxr-x 5 alice alice 4096 Aug 10 14:30 ..
-rw-rw-r-- 1 alice alice   12 Aug 10 14:30 config.txt
```

**What just happened:** The script checked before creating anything. The
first run created the directory and config file. The second run detected they
already existed and skipped the creation. The end result was identical both
times. This is idempotency — and every build script in the project works this
way, which is why `make build` is safe to re-run.

## Checkpoint

From your `~/linux-labs` directory, verify the following:

```
./safe.sh; echo "exit: $?"
```

Expected: the script fails (you see the `ls` error and `exit: 2`), and step
2 does not print.

```
./setup.sh
```

Expected: the script reports that the directory and config already exist (not
that it created them). This proves idempotency.

```
cat my-project/config.txt
```

Expected output:

```
version=1.0
```

If all three checks pass, you have completed this module.

## Key Takeaways

- A shell script is a text file of commands, starting with `#!/usr/bin/env
  bash`, made executable with `chmod +x`.
- Always use `set -euo pipefail` at the top of your scripts. It catches
  failures immediately instead of letting the script continue in a broken
  state.
- Exit code 0 means success. Anything else means failure. Use `$?` to check
  the last exit code.
- `trap` lets you run cleanup or diagnostics when an error occurs. Use it to
  print the failing line number.
- Idempotent scripts check before acting, so running them twice is safe. This
  is essential for build systems.

## How this connects to the project

Every build script in the Attested Agent Authority project sources
`scripts/lib/common.sh`, which sets `set -euo pipefail` and installs an
error trap that prints the failing script name and line number. You can see
this at the top of `common.sh`:

```bash
set -euo pipefail
```

and in its trap:

```bash
trap '_aaa_trap $LINENO' ERR
```

Every script is idempotent — if the network already exists, `10-network.sh`
says so and moves on. If the VM is already running, `20-workload.sh` skips
the creation. This is why `make build` can be re-run after a failure: it
picks up where it left off instead of crashing on things it already built.

The strict error handling means that if any step fails, the build stops
immediately and tells you which line in which script broke. You never have to
wonder whether a half-finished build left the system in an inconsistent state
— `set -e` guarantees it stopped before doing more damage.

## Next

[Module 03: Networking](../03-networking/README.md)
