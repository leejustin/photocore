import Testing

/// Every suite that runs Vision lives inside this one. Swift Testing would
/// otherwise run several culls at once, each with worker threads parked on
/// `VisionCompute.gate`, and Vision's own internal queues then starve for
/// threads and deadlock. Production never stacks culls this way: the app runs
/// one trip at a time and the server's job queue is serial.
@Suite(.serialized) enum VisionSuites {}
