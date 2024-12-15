import json
import matplotlib.pyplot as plt
import glob
import argparse

# Parse command-line arguments
parser = argparse.ArgumentParser(description="Plot metrics from JSON files.")
parser.add_argument("--use_vloss", action="store_true", help="Replace p0loss with vloss")
parser.add_argument("--nsamp_threshold", type=float, default=float('inf'), help="Threshold for nsamp values")
parser.add_argument("--metrics_path", type=str, default="*/train/*/metrics_train.json", help="Path to search for JSON files")
args = parser.parse_args()

# Path to search for JSON files
file_paths = glob.glob(args.metrics_path)

# Initialize lists to store data for plotting
plot_data = []

# Process each JSON file
for file_path in file_paths:
    try:
        # Load data from the JSON file
        with open(file_path, 'r') as file:
            logs = [json.loads(line) for line in file]

        # Extract nsamp and loss values, filtering based on nsamp_threshold
        nsamp = [entry["nsamp"] for entry in logs if "nsamp" in entry and entry["nsamp"] <= args.nsamp_threshold]
        loss_key = "vloss" if args.use_vloss else "p0loss"
        loss = [entry[loss_key] for entry in logs if loss_key in entry and entry.get("nsamp", float('inf')) <= args.nsamp_threshold]

        # Store the data for plotting
        plot_data.append((nsamp, loss, file_path))

    except Exception as e:
        print(f"Error processing file {file_path}: {e}")

# Plot all curves in one figure
plt.figure(figsize=(10, 6))
for nsamp, loss, file_path in plot_data:
    plt.plot(nsamp, loss, label=file_path)

plt.title("nsamp vs. loss for all files")
plt.xlabel("nsamp")
plt.ylabel("vloss" if args.use_vloss else "p0loss")
plt.grid(True)
plt.legend()
plt.show()
