# A traffic-light FSM as classes.

class State:
    name = "<unset>"
    def on_tick(self, ctx): ...

class Red(State):
    name = "red"
    def on_tick(self, ctx): ctx.transition(Green())

class Green(State):
    name = "green"
    def on_tick(self, ctx): ctx.transition(Yellow())

class Yellow(State):
    name = "yellow"
    def on_tick(self, ctx): ctx.transition(Red())


class TrafficLight:
    def __init__(self):
        self.state = Red()
        self.history = [self.state.name]

    def transition(self, new_state):
        self.state = new_state
        self.history.append(new_state.name)

    def tick(self):
        self.state.on_tick(self)


light = TrafficLight()
for _ in range(7):
    light.tick()

print(" → ".join(light.history))
