import std/strformat

import ffmpeg
import log

type
  Graph* = object
    graph: ptr AVFilterGraph
    nodes: seq[ptr AVFilterContext]
    bufferSource: ptr AVFilterContext
    bufferSink: ptr AVFilterContext
    configured: bool

  BlockingIOError* = object of CatchableError
  EOFError* = object of CatchableError

proc newGraph*(): Graph =
  result.graph = avfilter_graph_alloc()
  result.nodes = @[]
  result.configured = false

  if result.graph == nil:
    error "Could not allocate filter graph"

proc `=destroy`*(g: Graph) =
  if g.graph != nil:
    avfilter_graph_free(addr g.graph)

proc add*(graph: var Graph, name: string, filterArgs: string = ""): ptr AVFilterContext =
  if graph.configured:
    error "Cannot add filters after graph is configured"

  var filterCtx: ptr AVFilterContext = nil
  let args = if filterArgs.len > 0: filterArgs.cstring else: nil
  let filterName = &"filter_{graph.nodes.len}"

  let ret = avfilter_graph_create_filter(
    addr filterCtx,
    avfilter_get_by_name(name.cstring),
    filterName.cstring,
    args,
    nil,
    graph.graph
  )

  if ret < 0:
    error fmt"Cannot create filter '{name}': {ret}"

  graph.nodes.add(filterCtx)

  if name == "buffersink":
    graph.bufferSink = filterCtx

  return filterCtx

proc linkNodes*(graph: Graph, src: ptr AVFilterContext, filter: ptr AVFilterContext, sink: ptr AVFilterContext): Graph =
  ## Link multiple filter contexts in sequence (equivalent to PyAV's link_nodes)
  ## Returns self for method chaining
  if graph.configured:
    error "Cannot link nodes after graph is configured"

  # Link src -> filter
  var ret = avfilter_link(src, 0, filter, 0)
  if ret < 0:
    error fmt"Could not link source to filter: {ret}"

  # Link filter -> sink
  ret = avfilter_link(filter, 0, sink, 0)
  if ret < 0:
    error fmt"Could not link filter to sink: {ret}"

  return graph

proc configure*(graph: var Graph): var Graph =
  ## Configure the filter graph (equivalent to PyAV's configure)
  ## Returns self for method chaining
  if graph.configured:
    return graph

  let ret = avfilter_graph_config(graph.graph, nil)
  if ret < 0:
    error fmt"Could not configure filter graph: {ret}"

  graph.configured = true
  return graph

proc push*(graph: Graph, frame: ptr AVFrame) =
  if not graph.configured:
    error "Graph must be configured before pushing frames"

  if graph.bufferSource == nil:
    error "No buffer source available for pushing frames"

  let ret = av_buffersrc_write_frame(graph.bufferSource, frame)
  if ret < 0:
    error fmt"Error pushing frame to graph: {ret}"

proc pull*(graph: Graph): ptr AVFrame =
  # Caller responsible for freeing frames
  if not graph.configured:
    error "Graph must be configured before pulling frames"

  if graph.bufferSink == nil:
    error "No buffer sink available for pulling frames"

  var frame = av_frame_alloc()
  if frame == nil:
    error "Could not allocate frame for pulling"

  let ret = av_buffersink_get_frame(graph.bufferSink, frame)
  if ret < 0:
    av_frame_free(addr frame)
    if ret == AVERROR_EAGAIN: # EAGAIN - would block
      raise newException(BlockingIOError, "No frame available")
    elif ret == AVERROR_EOF:
      raise newException(EOFError, "End of stream")
    else:
      error fmt"Error pulling frame from graph: {ret}"

  return frame
