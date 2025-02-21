#!/bin/bash

# Path to your minishell executable. Adjust if necessary.
MINISHELL_PATH="../minishell"

# Path to valgrind executable. Ensure valgrind is installed.
VALGRIND_PATH="valgrind"

# Test input file. You can create or modify this file to add more test commands.
TEST_INPUT_FILE="./leak_tester/test_commands.txt"

# Create a simple test input file if it doesn't exist
if [ ! -f "$TEST_INPUT_FILE" ]; then
  cat > "$TEST_INPUT_FILE" <<EOF
echo hello world
ls -l
pwd
cd ..
exit
EOF
fi

# Compile minishell (assuming you have a Makefile)
echo "🛠️  Compiling minishell..."
make -C .. re > /dev/null 2>&1 # Suppress compilation output, remove "> /dev/null 2>&1" to see compilation logs
if [ $? -ne 0 ]; then
  echo "❌ Compilation failed. Please check your Makefile and project."
  exit 1
fi
echo "✅ Minishell compiled successfully."

echo "🧪 Running leak tests with Valgrind (per command)..."

total_leaks=0

while IFS= read -r command || [[ -n "$command" ]]; do # Process line by line, even with spaces
  if [[ -z "$command" ]]; then # Skip empty lines
    continue
  fi
  echo "  ➡️ Testing command: '$command'"

  # Run valgrind on minishell for *each* command individually using <<< (herestring)
  command_valgrind_output=$("$VALGRIND_PATH" --leak-check=full $MINISHELL_PATH <<< "$command" 2>&1)

  # Extract the number of definitely lost bytes using awk
  definitely_lost_bytes=$(echo "$command_valgrind_output" | awk '/definitely lost:/ {gsub(/[^0-9]/, "", $4); print $4}')

  if [ -n "$definitely_lost_bytes" ] && [ "$definitely_lost_bytes" -gt 0 ]; then
    echo "    🔴 Leaks DETECTED for command: '$command' ($definitely_lost_bytes bytes definitely lost)"
    total_leaks=$((total_leaks + definitely_lost_bytes))
    echo "    Valgrind output for command '$command':"
    echo "    --------------------------------------"
    echo "$command_valgrind_output"
    echo "    --------------------------------------"
  else
    echo "    🟢 No 'definitely lost' memory leaks detected for command: '$command'"
  fi
done < "$TEST_INPUT_FILE"

echo "📊 Final Leak Test Summary:"
echo "---------------------------"
echo "Total 'definitely lost' bytes detected across all commands: $total_leaks bytes"

if [ "$total_leaks" -gt 0 ]; then
  echo "🔴 Overall: Memory leaks detected! ($total_leaks bytes 'definitely lost' in total)"
  exit 1 # Exit with error code if leaks are found
else
  echo "🟢 Overall: No 'definitely lost' memory leaks detected in these tests."
  exit 0 # Exit with success code if no leaks are found
fi
