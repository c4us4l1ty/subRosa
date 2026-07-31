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

# 1. Variables

```python
age = 18
pi = 3.14
name = "John"
isPassed = True
```

### Input

```python
name = input("Name: ")
age = int(input("Age: "))
height = float(input("Height: "))
```

### Output

```python
print(name)
print(age, height)
print("Age =", age)
print(f"Hello {name}")
```

---

# 2. Operators

### Arithmetic

```python
+
-
*
/
%
**
//
```

Example

```python
7 // 2    #3
7 % 2     #1
2 ** 3    #8
```

### Comparison

```python
==
!=
<
>
<=
>=
```

### Logical

```python
and
or
not
```

---

# 3. Selection

```python
if mark >= 80:
    grade = "A"
elif mark >= 70:
    grade = "B"
else:
    grade = "C"
```

Nested

```python
if age >= 18:
    if citizen:
        print("Vote")
```

---

# 4. Loops

## For

```python
for i in range(10):
    print(i)
```

```python
for i in range(1,11):
```

```python
for i in range(10,0,-1):
```

## While

```python
while x < 10:
    x += 1
```

Infinite

```python
while True:
```

Exit

```python
break
continue
```

---

# 5. Strings

```python
text = "Computer"
```

### Index

```python
text[0]
text[-1]
```

### Slice

```python
text[2:5]
text[:4]
text[3:]
```

### Methods

```python
len(text)

text.upper()

text.lower()

text.find("put")

text.replace("C","B")

text.split(",")

",".join(list)

text.strip()
```

Membership

```python
if "Com" in text:
```

---

# 6. Lists (Arrays)

Create

```python
numbers = [4,2,7]
```

Access

```python
numbers[0]
```

Change

```python
numbers[1] = 10
```

Add

```python
numbers.append(5)
```

Insert

```python
numbers.insert(2,100)
```

Delete

```python
numbers.remove(7)

numbers.pop()

del numbers[1]
```

Loop

```python
for item in numbers:
```

Length

```python
len(numbers)
```

Sort

```python
numbers.sort()

numbers.sort(reverse=True)
```

Reverse

```python
numbers.reverse()
```

---

# 7. 2D Arrays

```python
grid = [[0]*5 for i in range(5)]
```

Access

```python
grid[2][3]
```

Loop

```python
for row in grid:
    for item in row:
        print(item)
```

---

# 8. Functions

```python
def greet():
    print("Hello")
```

Parameters

```python
def add(a,b):
    return a+b
```

Call

```python
x = add(5,7)
```

Default

```python
def area(r=5):
```

---

# 9. Recursion

```python
def factorial(n):
    if n == 0:
        return 1
    return n * factorial(n-1)
```

Always have:

* Base case
* Recursive call

---

# 10. Exception Handling

```python
try:
    x = int(input())
except ValueError:
    print("Invalid")
```

```python
try:
    file = open("data.txt")
except FileNotFoundError:
    print("Missing")
```

---

# 11. File Handling

Open

```python
file = open("data.txt","r")
```

Modes

```
r
w
a
```

Read

```python
line = file.readline()

text = file.read()

lines = file.readlines()
```

Write

```python
file.write("Hello")
```

Close

```python
file.close()
```

Best practice

```python
with open("data.txt","r") as file:
    data = file.read()
```

---

# 12. CSV

```python
line = file.readline()

values = line.split(",")
```

---

# 13. Searching

## Linear Search

```python
found = False

for i in range(len(arr)):
    if arr[i] == item:
        found = True
        position = i
```

Complexity

```
O(n)
```

---

## Binary Search

```python
low = 0
high = len(arr)-1

while low <= high:

    mid = (low+high)//2

    if arr[mid] == item:
        print("Found")

    elif item < arr[mid]:
        high = mid-1

    else:
        low = mid+1
```

Requires

* Sorted array

Complexity

```
O(log n)
```

---

# 14. Bubble Sort

```python
for i in range(len(arr)-1):

    for j in range(len(arr)-1-i):

        if arr[j] > arr[j+1]:

            arr[j],arr[j+1] = arr[j+1],arr[j]
```

Complexity

```
O(n²)
```

---

# 15. Insertion Sort

```python
for i in range(1,len(arr)):

    key = arr[i]

    j = i-1

    while j>=0 and arr[j]>key:

        arr[j+1]=arr[j]

        j-=1

    arr[j+1]=key
```

---

# 16. Stack (LIFO)

Push

```python
stack.append(item)
```

Pop

```python
stack.pop()
```

Peek

```python
stack[-1]
```

Empty

```python
len(stack)==0
```

---

# 17. Queue (FIFO)

Enqueue

```python
queue.append(item)
```

Dequeue

```python
queue.pop(0)
```

Front

```python
queue[0]
```

---

# 18. Dictionary

Create

```python
student = {}

student["Ali"] = 85
```

Access

```python
student["Ali"]
```

Loop

```python
for key in student:
```

---

# 19. Classes (OOP)

```python
class Student:

    def __init__(self,name,age):

        self.name=name

        self.age=age

    def display(self):

        print(self.name,self.age)
```

Object

```python
s = Student("Ali",18)

s.display()
```

---

# 20. Random

```python
import random
```

Integer

```python
random.randint(1,10)
```

Choice

```python
random.choice(list)
```

Shuffle

```python
random.shuffle(list)
```

---

# 21. Useful Built-ins

```python
len()

max()

min()

sum()

sorted()

int()

float()

str()

range()

enumerate()

zip()
```

---

# 22. Complexity

| Algorithm            | Complexity |
| -------------------- | ---------- |
| Linear Search        | O(n)       |
| Binary Search        | O(log n)   |
| Bubble Sort          | O(n²)      |
| Insertion Sort       | O(n²)      |
| Access Array         | O(1)       |
| Stack Push/Pop       | O(1)       |
| Queue Enqueue        | O(1)       |
| Queue Dequeue (list) | O(n)       |

---

# 23. Common Exam Patterns

### Count

```python
count = 0

for x in arr:
    if x > 50:
        count += 1
```

---

### Total

```python
total = 0

for x in arr:
    total += x
```

---

### Maximum

```python
largest = arr[0]

for x in arr:
    if x > largest:
        largest = x
```

---

### Minimum

```python
smallest = arr[0]
```

---

### Average

```python
average = sum(arr)/len(arr)
```

---

### Swap

```python
a,b = b,a
```

---

### Count Characters

```python
for ch in text:
```

---

### Reverse String

```python
text[::-1]
```

---

### Palindrome

```python
if word == word[::-1]:
```

---

### Count Frequency

```python
freq = {}

for x in arr:
    if x in freq:
        freq[x]+=1
    else:
        freq[x]=1
```

---

# 24. Must-Know Syntax

```python
append()

pop()

remove()

insert()

sort()

reverse()

split()

join()

strip()

upper()

lower()

find()

replace()

len()

range()

open()

read()

readline()

write()

close()

try

except

class

def

return

break

continue

pass

global
```
---
