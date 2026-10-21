# Group → aggregate → rank, with dicts, list comprehensions, and lambdas.

records = [
    {"name": "Alice",  "age": 30, "salary": 50000, "dept": "Eng"},
    {"name": "Bob",    "age": 25, "salary": 45000, "dept": "Eng"},
    {"name": "Carol",  "age": 35, "salary": 65000, "dept": "Mgr"},
    {"name": "Dave",   "age": 28, "salary": 55000, "dept": "Eng"},
    {"name": "Eve",    "age": 32, "salary": 70000, "dept": "Mgr"},
]

# group by dept
groups = {}
for r in records:
    groups.setdefault(r["dept"], []).append(r)

# aggregate per group
for dept in sorted(groups.keys()):
    people = groups[dept]
    total = sum(p["salary"] for p in people)
    avg = total // len(people)
    youngest = min(people, key=lambda p: p["age"])
    print(f"{dept}: {len(people)} people, total ${total}, avg ${avg}")
    print(f"  youngest: {youngest['name']} ({youngest['age']})")

# top earners
top = sorted(records, key=lambda r: -r["salary"])[:3]
print("top 3:", [r["name"] for r in top])
