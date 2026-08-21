# Module 01: Files, Users, Permissions

You will learn how Linux controls access to files: who owns them, who can
read or write them, and how the system decides. This matters for the final
project because the agent has full administrator power on its VM — it can
change any file permission it wants — which is precisely why permissions
alone cannot constrain it, and why AppArmor (Module 08) exists.

## Prerequisites

- [Module 00: The Terminal](../00-the-terminal/README.md)

## What you will need

- The same Ubuntu machine from Module 00.
- About 25-35 minutes.

## Concepts

### Everything is a file

Linux treats almost everything as a file. Your documents are files. The list
of users on the system is a file. The configuration for the network is a
file. Even hardware devices are represented as files. This means the same
permission system that protects your documents also protects the system's
configuration.

### Users, groups, and the root user

Linux is a multi-user system. Every person (and every program acting as a
person) has a **user account** with a username and a numeric **user ID**
(UID). Users also belong to one or more **groups** — named collections of
users that can share access to files.

One user is special: **root** (UID 0). Root is the system administrator. Root
can read any file, write any file, change any permission, and kill any
process. When you run a command with `sudo` ("superuser do"), you are running
that one command as root.

The Attested Agent Authority project gives the agent the root user's power
on its VM. That means file permissions cannot stop it — root overrides
them all. This is the reason the project needs something stronger than
permissions (AppArmor, measured by IMA, verified by the TPM).

### The permission string

Every file and directory has three sets of permissions: one for the **owner**
(the user who owns the file), one for the **group** (any user in the file's
group), and one for **others** (everyone else). Each set has three
permissions:

- **r** (read) — you can look at the file's contents.
- **w** (write) — you can change the file's contents.
- **x** (execute) — you can run the file as a program.

When you run `ls -l`, the first column shows the permission string. It looks
like this:

```
-rw-r--r-- 1 alice developers 42 Aug 10 14:00 report.txt
```

Breaking that first column down:

```
-   rw-   r--   r--
|    |     |     |
|    |     |     +-- others: read only
|    |     +-------- group: read only
|    +-------------- owner: read and write
+------------------- file type: - means regular file, d means directory
```

So this file can be read by anyone, but only the owner (`alice`) can write
to it.

### Numeric (octal) permissions

Each permission can also be written as a number:

- r = 4
- w = 2
- x = 1
- no permission = 0

You add them together for each set. So `rw-` = 4+2+0 = 6, `r--` = 4+0+0 =
4, and `---` = 0. The full permission is written as three digits: `644`
means the owner can read and write (6), the group can read (4), and others
can read (4). `755` means the owner can read, write, and execute (7), and
everyone else can read and execute (5).

Common permission numbers:

- `644` — owner reads and writes, everyone else reads (typical for text files)
- `755` — owner reads, writes, and executes, everyone else reads and executes
  (typical for programs and directories)
- `600` — only the owner can read and write (typical for private keys)
- `700` — only the owner can read, write, and execute (typical for private
  directories)

### Changing permissions with chmod

The **`chmod`** ("change mode") command changes a file's permissions. You can
use it two ways:

**Numeric:** Set all permissions at once.

```
chmod 644 myfile.txt
```

**Symbolic:** Add or remove specific permissions.

```
chmod u+x myscript.sh    # add execute for the owner (u = user/owner)
chmod g-w myfile.txt      # remove write for the group (g = group)
chmod o-r private.txt     # remove read for others (o = others)
chmod a+r public.txt      # add read for all (a = all)
```

### Changing ownership with chown

The **`chown`** ("change owner") command changes who owns a file. Only root
can change ownership (because otherwise you could give away files you do not
own).

```
sudo chown alice:developers report.txt
```

This sets the owner to `alice` and the group to `developers`.

### The /etc/passwd and /etc/shadow files

The system keeps its list of user accounts in `/etc/passwd`. Despite the
name, this file does not contain passwords — it contains usernames, user IDs,
home directories, and default shells. It is world-readable because many
programs need to look up usernames.

Actual password hashes are stored in `/etc/shadow`, which only root can read.
This separation exists so that programs can read usernames without being able
to read password hashes.

## Exercises

### Exercise 1: Find out who you are

Run the following commands:

```
whoami
```

**Expected output:** Your username (for example, `alice`).

```
id
```

**Expected output:** Your user ID, your primary group ID, and a list of all
groups you belong to. It looks something like:

```
uid=1000(alice) gid=1000(alice) groups=1000(alice),4(adm),27(sudo)
```

```
groups
```

**Expected output:** Just the group names, without the numbers:

```
alice adm sudo
```

**What just happened:** `whoami` tells you your username. `id` shows your
full identity including numeric IDs and group memberships. `groups` shows
just the group names. The `sudo` group is the one that lets you use `sudo`
to run commands as root.

### Exercise 2: Read the permission string

Navigate to your home directory and list files with full details:

```
cd ~
ls -l
```

**Expected output:** A list of your files and directories, each with a
permission string, owner, group, size, date, and name. For example:

```
drwxr-xr-x 2 alice alice 4096 Aug 10 10:00 Desktop
drwxr-xr-x 2 alice alice 4096 Aug 10 10:00 Documents
drwxr-xr-x 2 alice alice 4096 Aug 10 10:00 Downloads
```

Notice the `d` at the beginning of each line — that means these are
directories, not regular files. The `rwxr-xr-x` means the owner can read,
write, and enter the directory, while everyone else can read and enter it
but not create files in it.

### Exercise 3: Create a file and examine its permissions

```
cd ~/linux-labs
echo "This file has default permissions" > default.txt
ls -l default.txt
```

**Expected output:**

```
-rw-rw-r-- 1 alice alice 34 Aug 10 14:30 default.txt
```

(Your date and username will differ. The permissions may be `-rw-r--r--`
depending on your system's default settings.)

**What just happened:** When you create a file, it gets default permissions.
On most Ubuntu systems, that is `664` (owner and group can read and write,
others can read) or `644` (owner can read and write, everyone else can only
read). The exact default is controlled by something called `umask`, which you
can learn about later.

### Exercise 4: Change permissions and observe the effect

Remove all permissions for group and others:

```
chmod 600 default.txt
ls -l default.txt
```

**Expected output:**

```
-rw------- 1 alice alice 34 Aug 10 14:30 default.txt
```

Now only you (the owner) can read and write this file. Verify you can still
read it:

```
cat default.txt
```

**Expected output:**

```
This file has default permissions
```

Now set it to read-only for everyone:

```
chmod 444 default.txt
ls -l default.txt
```

**Expected output:**

```
-r--r--r-- 1 alice alice 34 Aug 10 14:30 default.txt
```

Try to write to it:

```
echo "trying to overwrite" > default.txt
```

**Expected output:** An error message:

```
bash: default.txt: Permission denied
```

**What just happened:** `chmod 444` removed write permission from everyone,
including you. The shell refused to open the file for writing. Restore write
permission so you can modify it again:

```
chmod 644 default.txt
```

### Exercise 5: See what root can do

Create a file and remove all permissions from it:

```
echo "secret data" > locked.txt
chmod 000 locked.txt
ls -l locked.txt
```

**Expected output:**

```
---------- 1 alice alice 12 Aug 10 14:35 locked.txt
```

No one has any permission to this file. Try to read it:

```
cat locked.txt
```

**Expected output:**

```
cat: locked.txt: Permission denied
```

Now try as root:

```
sudo cat locked.txt
```

**Expected output:**

```
secret data
```

**What just happened:** Even with all permissions removed, root can still
read the file. The permission system does not stop the administrator. This is
exactly the situation the project creates: the agent has root power, so file
permissions alone cannot constrain it.

Clean up by restoring permissions:

```
chmod 644 locked.txt
```

### Exercise 6: Examine system files

Look at the system's user database:

```
ls -l /etc/passwd
```

**Expected output:**

```
-rw-r--r-- 1 root root 2345 Aug 10 10:00 /etc/passwd
```

The file is owned by `root`, and everyone can read it. Look at its contents:

```
cat /etc/passwd
```

**Expected output:** A list of all user accounts on the system, one per line.
Each line has fields separated by colons. The first field is the username, the
third is the numeric user ID, and the sixth is the home directory. For
example:

```
root:x:0:0:root:/root:/bin/bash
alice:x:1000:1000:Alice,,,:/home/alice:/bin/bash
```

Now look at the shadow file:

```
ls -l /etc/shadow
```

**Expected output:**

```
-rw-r----- 1 root shadow 1234 Aug 10 10:00 /etc/shadow
```

Notice the permissions: `640`. Only root and members of the `shadow` group
can read it. Try reading it:

```
cat /etc/shadow
```

**Expected output:**

```
cat: /etc/shadow: Permission denied
```

Now try with sudo:

```
sudo cat /etc/shadow
```

**Expected output:** The contents of the shadow file. Each line starts with
a username, followed by a long string of characters — that is the hashed
password. You do not need to understand the hashing yet (that is Module 05).

**What just happened:** `/etc/passwd` is world-readable because programs need
to look up usernames. `/etc/shadow` is locked down because it contains
password hashes. This separation is a basic security measure — and one that
root can bypass completely.

### Exercise 7: Change ownership (with sudo)

Create a file and change its owner:

```
echo "owned by me" > ownership-demo.txt
ls -l ownership-demo.txt
```

**Expected output:**

```
-rw-rw-r-- 1 alice alice 12 Aug 10 14:40 ownership-demo.txt
```

Change the owner to root:

```
sudo chown root:root ownership-demo.txt
ls -l ownership-demo.txt
```

**Expected output:**

```
-rw-rw-r-- 1 root root 12 Aug 10 14:40 ownership-demo.txt
```

The file is now owned by root. Try to write to it:

```
echo "overwriting" > ownership-demo.txt
```

**Expected output:** This might succeed or fail depending on the group write
bit and your group membership. If the permissions show `rw-rw-r--` and you
are not in the root group, you may get `Permission denied`. If you see no
error, that is because the group write permission allows your group — check
the exact output.

Remove group write and try again:

```
sudo chmod 644 ownership-demo.txt
echo "overwriting" > ownership-demo.txt
```

**Expected output:**

```
bash: ownership-demo.txt: Permission denied
```

**What just happened:** Changing the owner to root and removing group write
means only root can write to the file. You, as a regular user, are now in the
"others" category — you can read it (the `4` in `644`) but not write it.

Clean up:

```
sudo chown $(whoami):$(whoami) ownership-demo.txt
```

### Exercise 8: Symbolic chmod

Practice the symbolic form of chmod:

```
echo "test file" > symbolic-demo.txt
ls -l symbolic-demo.txt
```

Add execute permission for the owner:

```
chmod u+x symbolic-demo.txt
ls -l symbolic-demo.txt
```

**Expected output:** The permission string now shows `x` in the owner
section: `-rwxrw-r--` or `-rwxr--r--`.

Remove read permission for others:

```
chmod o-r symbolic-demo.txt
ls -l symbolic-demo.txt
```

**Expected output:** The last `r` is gone: `-rwxrw----` or `-rwxr-----`.

**What just happened:** Symbolic chmod lets you add (`+`) or remove (`-`)
specific permissions for the owner (`u`), group (`g`), others (`o`), or
everyone (`a`). This is often clearer than remembering the numeric codes.

## Checkpoint

From your `~/linux-labs` directory, run:

```
ls -l default.txt locked.txt
```

Expected output: Both files exist with `644` permissions (`-rw-r--r--`).

```
stat -c "%a %U" default.txt
```

Expected output:

```
644 alice
```

(Your username instead of `alice`.)

If you see the expected permissions and ownership, you have completed
this module.

## Key Takeaways

- Every file has an owner, a group, and three sets of permissions (read,
  write, execute) for owner, group, and others.
- `chmod` changes permissions. You can use numeric notation (`chmod 644`) or
  symbolic notation (`chmod u+x`).
- `chown` changes ownership. Only root can do this.
- Root (the superuser) bypasses all file permissions. `sudo` lets you run a
  single command as root.
- `/etc/passwd` is world-readable (usernames). `/etc/shadow` is restricted
  (password hashes). This separation is intentional.

## How this connects to the project

The Attested Agent Authority agent has root power on its VM. Root overrides
every file permission — you proved this in Exercise 5. This means file
permissions alone cannot stop the agent from reading or writing whatever it
wants, including its own AppArmor profile.

The project's build script (`scripts/40-apparmor.sh`) deliberately sets the
agent's AppArmor profile to `0644` owned by the agent's user (`harden`). The
agent can write its own constraint file. The write succeeds — and that is
exactly the point. Permission did not stop the agent. What stops the agent is
that the write changes the file's hash, the IMA log records the new hash, the
TPM quote reflects the change, the verifier's check fails, and the
certificate is not renewed. The agent is not denied — it is defunded.

AppArmor (Module 08) constrains what even root can do. But the deeper lesson
of this module is that file permissions, by themselves, are not enough to
constrain an administrator.

## Next

[Module 02: Shell Scripting](../02-shell-scripting/README.md)
