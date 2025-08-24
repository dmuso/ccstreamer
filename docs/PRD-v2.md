# Product Requirements Document: CC Streamer v2

## Executive Summary

CC Streamer v2 enhances the terminal output formatting of Claude Code's JSON stream to provide a more user-friendly, visually distinguished, and cleaner display experience. The primary focus is on improving readability through color-coded output types, content-focused display, and proper formatting of message content.

## Problem Statement

Current limitations of v1:
- All output appears in the same color, making it difficult to distinguish between different message types
- Raw JSON structure is displayed, creating visual clutter
- Escaped characters (like line breaks) are shown literally rather than being rendered
- Users see unnecessary metadata when they primarily care about message content

## Goals

1. **Enhanced Visual Distinction**: Use colors to differentiate between message types
2. **Content-First Display**: Focus on showing `message.content` clearly
3. **Proper Formatting**: Render escaped characters correctly (line breaks, tabs, etc.)
4. **Clean Output**: Remove unnecessary JSON structure from stdout

## Requirements

### Functional Requirements

#### FR1: Dynamic Color Assignment System
- Implement a programmatic color assignment system for different message types
- Maintain a pool of distinct terminal colors
- Dynamically assign colors to message types as they are encountered in the stream
- Ensure consistent color assignment for the same type throughout a session
- No hard-coding of specific types to colors

#### FR2: Content-Focused Display
- Extract and prominently display `message.content` field
- Hide or minimize display of other JSON metadata
- Preserve important contextual information where necessary
- Implement smart detection of what constitutes "important" vs "noise"

#### FR3: Proper Character Rendering
- Correctly interpret and render escaped characters:
  - `\n` → actual line break
  - `\t` → actual tab
  - `\"` → quote character
  - Other standard JSON escape sequences
- Maintain formatting integrity of code blocks and structured content

#### FR4: Type-Based Formatting
- Apply consistent formatting rules based on message type
- Support different display strategies for different types:
  - Text messages
  - Code blocks
  - Error messages
  - Status updates
  - Tool invocations
  - Tool results

### Non-Functional Requirements

#### NFR1: Performance
- Maintain real-time streaming capability
- No noticeable lag in processing and displaying messages
- Efficient color assignment algorithm

#### NFR2: Compatibility
- Support standard ANSI color codes
- Work across common terminal emulators
- Gracefully degrade in terminals without color support

#### NFR3: Configurability
- Allow users to customize color schemes (future enhancement)
- Support NO_COLOR environment variable for accessibility

## Technical Design

### Color Management System

```
ColorManager:
  - availableColors: []Color
  - typeColorMap: HashMap<String, Color>
  - assignedColors: Set<Color>
  
  Methods:
  - getColorForType(type: String) -> Color
  - recycleUnusedColors()
  - resetColorAssignments()
```

### Message Processing Pipeline

1. **Parse Stage**: Extract JSON from stream
2. **Type Detection**: Identify message type field
3. **Color Assignment**: Get or assign color for type
4. **Content Extraction**: Pull out message.content
5. **Format Stage**: Apply escape sequence processing
6. **Render Stage**: Output formatted, colored text

### Color Pool Strategy

Suggested initial color pool (ANSI codes):
- Bright Blue (94)
- Bright Green (92)
- Bright Yellow (93)
- Bright Magenta (95)
- Bright Cyan (96)
- White (97)
- Blue (34)
- Green (32)
- Yellow (33)
- Magenta (35)

Reserve red tones for errors/warnings.

## User Experience

### Example Output Transformation

**Current (v1):**
```json
{"type":"text","message":{"content":"Hello, I'll help you with that task.\nLet me check the files."},"timestamp":"..."}
```

**Proposed (v2):**
```
[TEXT] Hello, I'll help you with that task.
       Let me check the files.
```
(Where [TEXT] appears in assigned color, e.g., bright blue)

### Type Indicators

Minimal type indicators with color coding:
- Text messages: No prefix, just colored text
- Tool invocations: Colored prefix like `[TOOL]` or icon
- Errors: Red colored with `[ERROR]` prefix
- Status: Dimmed color with minimal formatting

## Success Metrics

1. **Readability**: Users can quickly distinguish between different message types
2. **Clarity**: Primary content (message.content) is immediately visible
3. **Performance**: No degradation in streaming performance
4. **Adoption**: Positive user feedback on improved output formatting

## Implementation Phases

### Phase 1: Core Color System
- Implement ColorManager
- Basic type detection
- Color assignment logic

### Phase 2: Content Extraction
- Parse and extract message.content
- Hide unnecessary JSON structure
- Basic formatting

### Phase 3: Escape Sequence Processing
- Implement proper character rendering
- Handle all standard JSON escapes
- Preserve formatting integrity

### Phase 4: Polish & Optimization
- Performance optimization
- Edge case handling
- Configuration options

## Testing Requirements

1. **Unit Tests**: Color assignment, content extraction, escape processing
2. **Integration Tests**: Full pipeline with various message types
3. **Performance Tests**: Streaming performance with color processing
4. **Compatibility Tests**: Different terminal emulators

## Future Enhancements

- User-configurable color schemes
- Theme support (light/dark mode)
- Syntax highlighting for code blocks
- Folding/expanding of verbose output
- Export to HTML with colors preserved
- Support for custom type-to-format mappings

## Appendix: Message Type Examples

Common message types expected from Claude Code:
- `text`: Regular text responses
- `tool_use`: Tool invocation messages
- `tool_result`: Results from tool execution
- `error`: Error messages
- `thinking`: Internal reasoning (if applicable)
- `code`: Code blocks or snippets
- `status`: Status updates

Each type should receive consistent, distinctive formatting throughout the session.