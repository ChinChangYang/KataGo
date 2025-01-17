import json
import matplotlib.pyplot as plt
import glob
import argparse
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import queue

# Queue for communicating between threads
plot_update_queue = queue.Queue()


def process_metrics_file(args):
    file_paths = glob.glob(args.metrics_path)
    plot_data = []

    for file_path in file_paths:
        try:
            with open(file_path, "r") as file:
                logs = [json.loads(line) for line in file]

            nsamp = [
                entry["nsamp"]
                for entry in logs
                if "nsamp" in entry and entry["nsamp"] <= args.nsamp_threshold
            ]
            loss_key = args.metric
            loss = [
                entry[loss_key]
                for entry in logs
                if loss_key in entry
                and entry.get("nsamp", float("inf")) <= args.nsamp_threshold
            ]

            parent_directory = os.path.basename(os.path.dirname(file_path))
            plot_data.append((nsamp, loss, parent_directory))
        except Exception as e:
            print(f"Error processing file {file_path}: {e}")

    return plot_data


class MetricsEventHandler(FileSystemEventHandler):
    def __init__(self, args):
        self.args = args

    def on_modified(self, event):
        if event.src_path.endswith(".json"):
            print(f"File modified: {event.src_path}")
            plot_update_queue.put("update")  # Signal an update


def update_plot(args):
    # Initial plot
    plot_data = process_metrics_file(args)
    plt.ion()
    plt.figure()
    while True:
        # Check for updates in the queue
        try:
            plot_update_queue.get_nowait()  # Non-blocking
            print("Updating plot...")
            plot_data = process_metrics_file(args)
        except queue.Empty:
            pass  # No updates, continue

        # Sort the plot data by parent_directory (label)
        plot_data.sort(key=lambda x: x[2])  # x[2] is the parent_directory

        # Update the plot
        plt.clf()
        for nsamp, loss, parent_directory in plot_data:
            plt.plot(nsamp, loss, label=parent_directory)

        plt.xscale("log")  # Set x-axis to log scale

        # Conditional Y-axis scaling
        if args.metric == "pslr_batch":
            plt.yscale("log")  # Set y-axis to log scale for pslr_batch
        else:
            plt.yscale("linear")  # Set y-axis to linear scale for other metrics

        plt.title(f"nsamp vs. {args.metric} for all files")
        plt.xlabel("nsamp")
        plt.ylabel(args.metric)
        plt.grid(True, which="both", ls="--", linewidth=0.5)
        plt.legend()
        plt.draw()
        plt.pause(3)  # Keep the GUI responsive


# Parse command-line arguments
parser = argparse.ArgumentParser(description="Plot metrics from JSON files.")
parser.add_argument(
    "--metric",
    type=str,
    choices=["p0loss", "vloss", "pslr_batch"],
    default="p0loss",
    help="Metric to plot: p0loss, vloss, or pslr_batch",
)
parser.add_argument(
    "--nsamp_threshold",
    type=float,
    default=float("inf"),
    help="Threshold for nsamp values",
)
parser.add_argument(
    "--metrics_path",
    type=str,
    default="*/train/*/metrics_train.json",
    help="Path to search for JSON files",
)

args = parser.parse_args()

# Set up the watchdog observer
path_to_watch = os.path.commonpath(
    [os.path.dirname(path) for path in glob.glob(args.metrics_path)]
)
observer = Observer()
handler = MetricsEventHandler(args)
observer.schedule(handler, path=path_to_watch, recursive=True)

# Start the observer and plot updater
observer.start()
print(f"Watching for changes in: {path_to_watch}")

try:
    update_plot(args)  # Run plot updater in the main thread
except KeyboardInterrupt:
    observer.stop()
    plt.close()
observer.join()
