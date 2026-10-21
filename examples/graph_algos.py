# Graph BFS, topological sort, recursive path counting.

graph = {
    "A": ["B", "C"],
    "B": ["D"],
    "C": ["D", "E"],
    "D": ["F"],
    "E": ["F"],
    "F": [],
}


def bfs(graph, start):
    visited, queue, order = set(), [start], []
    while queue:
        node = queue.pop(0)
        if node in visited:
            continue
        visited.add(node)
        order.append(node)
        for neighbor in graph[node]:
            if neighbor not in visited:
                queue.append(neighbor)
    return order


def topo_sort(graph):
    in_degree = {node: 0 for node in graph}
    for node in graph:
        for n in graph[node]:
            in_degree[n] += 1
    ready = [n for n in graph if in_degree[n] == 0]
    order = []
    while ready:
        ready.sort()  # deterministic
        node = ready.pop(0)
        order.append(node)
        for n in graph[node]:
            in_degree[n] -= 1
            if in_degree[n] == 0:
                ready.append(n)
    return order


def count_paths(graph, start, end):
    if start == end:
        return 1
    return sum(count_paths(graph, n, end) for n in graph[start])


print("BFS from A:", bfs(graph, "A"))
print("topo:      ", topo_sort(graph))
print("A→F paths: ", count_paths(graph, "A", "F"))
