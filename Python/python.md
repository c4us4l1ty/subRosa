// Procedure to sort a 1D array of integers in ascending order
PROCEDURE BubbleSort(BYREF List : ARRAY, DECLARE Length : INTEGER)
    DECLARE Pass : INTEGER
    DECLARE Index : INTEGER
    DECLARE Temp : INTEGER
    DECLARE Swapped : BOOLEAN
    
    DECLARE UpperBound : INTEGER
    UpperBound ← Length - 1
    
    REPEAT
        Swapped ← FALSE
        
        FOR Index ← 1 TO UpperBound
            IF List[Index] > List[Index + 1] THEN
                // Swap adjacent elements
                Temp ← List[Index]
                List[Index] ← List[Index + 1]
                List[Index + 1] ← Temp
                
                Swapped ← TRUE
            ENDIF
        NEXT Index
        
        // Optimization: Reduce upper bound after each pass 
        // as the largest element reaches its final position
        UpperBound ← UpperBound - 1
        
    UNTIL Swapped = FALSE OR UpperBound = 0
ENDPROCEDURE

1. Advanced File Handling (Text & CSV)
Text Files
Python

# Writing (overwrites file)
file = open("data.txt", "w")
file.write("Line 1\n")
file.writelines(["Line 2\n", "Line 3\n"])
file.close()

# Appending
file = open("data.txt", "a")
file.write("New data\n")
file.close()

# Reading safely (Context Manager - Recommended)
with open("data.txt", "r") as file:
    content = file.read()       # Entire file as a single string
    # lines = file.readlines()  # List of strings (with \n)
    # line = file.readline()    # Single line

CSV Handling via String Manipulation
Python

with open("records.csv", "r") as file:
    for line in file:
        fields = line.strip().split(",")
        print(f"ID: {fields[0]}, Name: {fields[1]}")

2. Object-Oriented Programming (OOP)
Python

class Person:
    # Constructor
    def __init__(self, name, age):
        self.__name = name      # Private attribute (encapsulation)
        self.__age = age

    # Getter methods
    def get_name(self):
        return self.__name

    def get_age(self):
        return self.__age

    # Setter methods
    def set_age(self, age):
        self.__age = age

    def display(self):
        print(f"Name: {self.__name}, Age: {self.__age}")


# Inheritance
class Student(Person):
    def __init__(self, name, age, student_id):
        super().__init__(name, age)  # Call parent constructor
        self.__student_id = student_id

    # Polymorphism / Method Overriding
    def display(self):
        super().display()
        print(f"Student ID: {self.__student_id}")

# Object Instantiation
s1 = Student("Alice", 20, "S1092")
s1.display()

3. Sorting & Searching Algorithms
Binary Search (Requires Sorted Array)
Python

def binary_search(arr, target):
    low = 0
    high = len(arr) - 1
    
    while low <= high:
        mid = (low + high) // 2
        if arr[mid] == target:
            return mid          # Found index
        elif target < arr[mid]:
            high = mid - 1      # Search left half
        else:
            low = mid + 1       # Search right half
    return -1                   # Not found

Bubble Sort
Python

def bubble_sort(arr):
    n = len(arr)
    for i in range(n):
        swapped = False
        for j in range(0, n - i - 1):
            if arr[j] > arr[j + 1]:
                arr[j], arr[j + 1] = arr[j + 1], arr[j]  # Swap
                swapped = True
        if not swapped:  # Optimization: break if already sorted
            break
    return arr

Insertion Sort
Python

def insertion_sort(arr):
    for i in range(1, len(arr)):
        key = arr[i]
        j = i - 1
        while j >= 0 and arr[j] > key:
            arr[j + 1] = arr[j]
            j -= 1
        arr[j + 1] = key
    return arr

4. Abstract Data Types (ADTs)
Stack (LIFO - Last In, First Out)

Implemented using a standard Python list.
Python

stack = []

# Push
stack.append("A")

# Pop
if len(stack) > 0:
    item = stack.pop()

# Peek
if len(stack) > 0:
    top_item = stack[-1]

Queue (FIFO - First In, First Out)
Python

queue = []

# Enqueue
queue.append("A")

# Dequeue
if len(queue) > 0:
    item = queue.pop(0)

# Front peek
if len(queue) > 0:
    front_item = queue[0]

Linked Nodes (Paper 4 Pointer-based structures)
Python

class Node:
    def __init__(self, data, next_pointer):
        self.data = data
        self.next_pointer = next_pointer

# Creating a static array of nodes simulating pointers
nodes = [Node("Apple", 1), Node("Banana", 2), Node("Cherry", -1)]
head_pointer = 0

current = head_pointer
while current != -1:
    print(nodes[current].data)
    current = nodes[current].next_pointer

5. Recursion (Advanced Patterns)
Recursive Factorial
Python

def factorial(n):
    if n == 0 or n == 1:  # Base Case
        return 1
    return n * factorial(n - 1)  # Recursive Step

Recursive Binary Search
Python

def recursive_binary_search(arr, low, high, target):
    if low > high:
        return -1
    
    mid = (low + high) // 2
    if arr[mid] == target:
        return mid
    elif target < arr[mid]:
        return recursive_binary_search(arr, low, mid - 1, target)
    else:
        return recursive_binary_search(arr, mid + 1, high, target)

pass

global
```
---


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

