#!/bin/bash

# Path to your minishell executable. Adjust if necessary.
MINISHELL_PATH="../minishell"

# Path to valgrind executable. Ensure valgrind is installed.
VALGRIND_PATH="valgrind"

# Test input file. You can create or modify this file to add more test commands.
TEST_INPUT_FILE="test_commands.txt"

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

echo "🧪 Running leak tests with Valgrind (per command, reporting adjusted still reachable occurrences and separate lines)..."

total_leaks=0
readline_leaks=0 # Counter for readline related leaks (for informational purposes)
total_still_reachable=0 # Counter for total still reachable bytes
total_adjusted_still_reachable_occurrences=0 # Counter for adjusted still reachable occurrences

while IFS= read -r command || [[ -n "$command" ]]; do # Process line by line, even with spaces
  if [[ -z "$command" ]]; then # Skip empty lines
    continue
  fi
  echo "  ➡️ Testing command: '$command'"

  # Run valgrind on minishell for *each* command individually using <<< (herestring)
  command_valgrind_output=$("$VALGRIND_PATH" --leak-check=full --show-leak-kinds=all $MINISHELL_PATH <<< "$command" 2>&1)

  # Use awk to process Valgrind output and identify non-readline leaks and still reachable bytes
  leak_info=$(echo "$command_valgrind_output" | awk '
    /definitely lost:/{
      definitely_lost_line = $0;
      match(definitely_lost_line, /definitely lost: +([0-9]+) bytes/, def_bytes_match);
      definitely_lost_bytes = def_bytes_match[1];

      still_reachable_bytes = 0; # Initialize still_reachable_bytes to 0
      still_reachable_line = "";

      # Find the "still reachable" line and extract bytes
      while(getline){
        if ($0 ~ /still reachable:/){
          still_reachable_line = $0;
          match(still_reachable_line, /still reachable: +([0-9]+) bytes/, still_bytes_match);
          still_reachable_bytes = still_bytes_match[1];
          break; # Found and extracted, exit loop
        }
        if ($0 ~ /LEAK SUMMARY:/){ # Stop searching if LEAK SUMMARY is reached without finding "still reachable"
          break;
        }
      }

      is_readline_leak = 0;

      # Check stack trace for readline (simplified check - adjust if needed)
      getline; getline; getline; getline; getline; getline; # Skip header lines to reach stack trace start
      while (getline) {
        if ($0 ~ /readline/ || $0 ~ /rl_/) {
          is_readline_leak = 1;
          break;
        }
        if ($0 ~ /==[0-9]+==/) { # Stop if next valgrind block starts (end of stack trace)
          break;
        }
        if (NF == 0) { # Stop on empty line (end of stack trace)
          break;
        }
      }

      if (is_readline_leak == 1) {
        printf "readline_leak=%s\ndefinitely_lost_bytes=%s\nstill_reachable_bytes=%s\n", is_readline_leak, definitely_lost_bytes, still_reachable_bytes;
      } else {
        printf "readline_leak=%s\ndefinitely_lost_bytes=%s\nstill_reachable_bytes=%s\n", is_readline_leak, definitely_lost_bytes, still_reachable_bytes;
      }
    }
  ')

  # Parse awk output to get leak info
  if [[ -n "$leak_info" ]]; then
    readline_leak=$(echo "$leak_info" | grep -oP 'readline_leak=\K[^[:space:]]+')
    definitely_lost_bytes=$(echo "$leak_info" | grep -oP 'definitely_lost_bytes=\K[^[:space:]]+')
    still_reachable_bytes=$(echo "$leak_info" | grep -oP 'still_reachable_bytes=\K[^[:space:]]+')

    still_reachable_occurrences_raw=$(echo "$command_valgrind_output" | grep -c "still reachable")
    readline_occurrences_raw=$(echo "$command_valgrind_output" | grep -c " readline ")
    adjusted_still_reachable_occurrences=$((still_reachable_occurrences_raw - (readline_occurrences_raw + 1)))

    if [[ "$definitely_lost_bytes" -gt 0 ]]; then
      if [[ "$readline_leak" == "1" ]]; then
        echo "    ℹ️  Readline-related leaks DETECTED for command: '$command'"
        echo "        Definitely lost: $definitely_lost_bytes bytes (EXCLUDING from total)"
        echo "        Still reachable: $still_reachable_bytes bytes"
        echo "        Adjusted still reachable occurrences: $adjusted_still_reachable_occurrences"
        readline_leaks=$((readline_leaks + definitely_lost_bytes)) # Count readline leaks separately
      else
        echo "    🔴 Leaks DETECTED for command: '$command'"
        echo "        Definitely lost: $definitely_lost_bytes bytes"
        echo "        Still reachable: $still_reachable_bytes bytes"
        echo "        Adjusted still reachable occurrences: $adjusted_still_reachable_occurrences"
        total_leaks=$((total_leaks + definitely_lost_bytes))
        echo "    Valgrind output for command '$command':"
        echo "    --------------------------------------"
        echo "$command_valgrind_output"
        echo "    --------------------------------------"
      fi
    else
      echo "    🟢 No 'definitely lost' memory leaks detected for command: '$command'"
      echo "        Still reachable: $still_reachable_bytes bytes"
      echo "        Adjusted still reachable occurrences: $adjusted_still_reachable_occurrences"
    fi
    total_still_reachable=$((total_still_reachable + still_reachable_bytes))
    total_adjusted_still_reachable_occurrences=$((total_adjusted_still_reachable_occurrences + adjusted_still_reachable_occurrences))
  else
    echo "    🟢 No 'definitely lost' memory leaks detected for command: '$command' (Still reachable info not found, Adjusted still reachable occurrences: N/A)"
  fi

done < "$TEST_INPUT_FILE"

echo "📊 Final Leak Test Summary:"
echo "---------------------------"
echo "Total 'definitely lost' bytes detected (excluding readline related): $total_leaks bytes"
echo "Total 'definitely lost' bytes detected (readline related - informational): $readline_leaks bytes"
echo "Total 'still reachable' bytes detected: $total_still_reachable bytes"
echo "Total adjusted 'still reachable' occurrences (still reachable count - (readline count + 1)): $total_adjusted_still_reachable_occurrences"

if [[ "$total_leaks" -gt 0 ]]; then
  echo "🔴 Overall: Memory leaks detected (excluding readline)! ($total_leaks bytes 'definitely lost' in total)"
  exit 1 # Exit with error code if leaks are found (excluding readline)
elif [[ "$total_adjusted_still_reachable_occurrences" -gt 1 ]]; then
  echo "🔴 Overall: Adjusted still reachable occurrences are greater than 1! (Total adjusted occurrences: $total_adjusted_still_reachable_occurrences)"
  exit 1 # Exit with error code if adjusted_still_reachable_occurrences > 1
else
  echo "🟢 Overall: No 'definitely lost' memory leaks detected in these tests (excluding readline)."
  if [ "$readline_leaks" -gt 0 ]; then
    echo "ℹ️  However, there were readline-related leaks (informational): $readline_leaks bytes."
  fi
  echo "ℹ️  Total 'still reachable' bytes (informational): $total_still_reachable bytes."
  echo "ℹ️  Total adjusted 'still reachable' occurrences (informational): $total_adjusted_still_reachable_occurrences."
  exit 0 # Exit with success code if no leaks are found (excluding readline) and adjusted_still_reachable_occurrences <= 1
fi
