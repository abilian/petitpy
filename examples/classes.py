# Inheritance, @property, custom descriptors.

class Doubler:
    """A non-data descriptor that doubles whatever attribute it's looking at."""
    def __init__(self, attr_name):
        self.attr = attr_name
    def __get__(self, obj, owner):
        return getattr(obj, self.attr) * 2


class Point:
    twice_x = Doubler("x")

    def __init__(self, x, y):
        self.x = x
        self.y = y

    @property
    def magnitude(self):
        return (self.x ** 2 + self.y ** 2) ** 0.5

    def __repr__(self):
        return f"Point({self.x}, {self.y})"


class Point3D(Point):
    def __init__(self, x, y, z):
        super().__init__(x, y)
        self.z = z

    @property
    def magnitude(self):
        return (self.x ** 2 + self.y ** 2 + self.z ** 2) ** 0.5

    def __repr__(self):
        return f"Point3D({self.x}, {self.y}, {self.z})"


p = Point(3, 4)
print(p, p.magnitude, "twice x =", p.twice_x)

q = Point3D(1, 2, 2)
print(q, q.magnitude)
print("isinstance:", isinstance(q, Point), isinstance(p, Point3D))
