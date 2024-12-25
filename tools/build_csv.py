import json
import csv

# Load JSON data from the file
with open('thruster_profile.json', 'r') as json_file:
    data = json.load(json_file)

# Open a CSV file for writing
with open('thruster_profile.csv', 'w', newline='') as csv_file:
    writer = csv.writer(csv_file)

    # Write the header row
    writer.writerow(['Level', 'Average Acceleration (m/s^2)', 'Thruster Force (N)'])

    # Write the data rows
    for level, values in enumerate(data):
        writer.writerow([level+1, values['acceleration'], values['force']])

print("Data has been successfully written to thruster_profile.csv")
