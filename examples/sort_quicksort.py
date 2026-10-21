# Quicksort via slicing + recursion + comprehensions.

def quicksort(arr):
    if len(arr) <= 1:
        return arr
    pivot = arr[0]
    less    = [x for x in arr[1:] if x < pivot]
    equal   = [x for x in arr    if x == pivot]
    greater = [x for x in arr[1:] if x > pivot]
    return quicksort(less) + equal + quicksort(greater)


nums = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9]
print("input :", nums)
print("sorted:", quicksort(nums))

# Mixed strings.
words = ["pear", "apple", "banana", "cherry", "ant"]
print("words sorted:", quicksort(words))
