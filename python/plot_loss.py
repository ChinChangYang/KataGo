import json
import matplotlib.pyplot as plt
import glob
import argparse
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import threading
import queue

# Queue for communicating between threads
plot_update_queue = queue.Queue()

def process_metrics_file(args):
    file_paths = glob.glob(args.metrics_path)
    plot_data = []

    for file_path in file_paths:
        try:
            with open(file_path, 'r') as file:
                logs = [json.loads(line) for line in file]

            nsamp = [entry["nsamp"] for entry in logs if "nsamp" in entry and entry["nsamp"] <= args.nsamp_threshold]
            loss_key = "vloss" if args.use_vloss else "p0loss"
            loss = [entry[loss_key] for entry in logs if loss_key in entry and entry.get("nsamp", float('inf')) <= args.nsamp_threshold]

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

        # Update the plot
        plt.clf()
        for nsamp, loss, parent_directory in plot_data:
            plt.plot(nsamp, loss, label=parent_directory)

        plt.title("nsamp vs. loss for all files")
        plt.xlabel("nsamp")
        plt.ylabel("vloss" if args.use_vloss else "p0loss")
        plt.grid(True)
        plt.legend()
        plt.draw()
        plt.pause(0.5)  # Keep the GUI responsive

# Parse command-line arguments
parser = argparse.ArgumentParser(description="Plot metrics from JSON files.")
parser.add_argument("--use_vloss", action="store_true", help="Replace p0loss with vloss")
parser.add_argument("--nsamp_threshold", type=float, default=float('inf'), help="Threshold for nsamp values")
parser.add_argument("--metrics_path", type=str, default="*/train/*/metrics_train.json", help="Path to search for JSON files")
args = parser.parse_args()

# Set up the watchdog observer
path_to_watch = os.path.commonpath([os.path.dirname(path) for path in glob.glob(args.metrics_path)])
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
