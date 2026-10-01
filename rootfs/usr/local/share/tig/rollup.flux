// Hourly downsample from the 90-day raw bucket into the 2-year rollup bucket.
//
// Gauges are averaged; counters keep their last value so a derivative over the
// rollup still gives a true rate. String fields are dropped: they cannot be
// averaged and nothing graphs them.

//
// The 5-minute offset only delays when the task runs, so late-arriving points
// are included. Inside the task now() is still the scheduled time, on the
// hour, so range(start: -task.every) is exactly the previous clock hour and
// lines up with the hourly windows.

import "types"

option task = {name: "rollup-1h", every: 1h, offset: 5m}

counters = ["diskio", "net", "mysql_status", "postgres_status"]

numeric =
    from(bucket: "telegraf")
        |> range(start: -task.every)
        |> filter(fn: (r) => types.isNumeric(v: r._value))

numeric
    |> filter(fn: (r) => not contains(value: r._measurement, set: counters))
    |> toFloat()
    |> aggregateWindow(every: 1h, fn: mean, createEmpty: false)
    |> to(bucket: "telegraf_rollup")

numeric
    |> filter(fn: (r) => contains(value: r._measurement, set: counters))
    |> toFloat()
    |> aggregateWindow(every: 1h, fn: last, createEmpty: false)
    |> to(bucket: "telegraf_rollup")
