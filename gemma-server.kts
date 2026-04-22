#!/usr/bin/env kscript
// Alternative (without kscript): rename to gemma-server.main.kts and replace
// @file:MavenRepository lines with @file:Repository("https://dl.google.com/android/maven2")
// then run: kotlin gemma-server.main.kts [model_path]

@file:MavenRepository("google-maven", "https://dl.google.com/android/maven2")
@file:DependsOn("com.google.ai.edge.litertlm:litertlm-jvm:0.10.2")
@file:DependsOn("io.ktor:ktor-server-netty-jvm:3.1.3")
@file:DependsOn("io.ktor:ktor-server-content-negotiation-jvm:3.1.3")
@file:DependsOn("io.ktor:ktor-serialization-kotlinx-json-jvm:3.1.3")
@file:DependsOn("io.ktor:ktor-server-cors-jvm:3.1.3")
@file:DependsOn("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
@file:DependsOn("org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.10.2")

import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.SamplerConfig
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.plugins.cors.routing.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.utils.io.*
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlin.system.exitProcess

// ── Constants ──────────────────────────────────────────────────────────────────

const val PORT = 8080
const val MODEL_ID = "gemma-4-E2B"
const val DEFAULT_MODEL_PATH = "models/gemma-4-E2B-it.litertlm"

// ── JSON serialiser ────────────────────────────────────────────────────────────

val json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = false
    isLenient = true
}

// ── OpenAI-compatible request / response data classes ─────────────────────────

@Serializable
data class ChatMessage(
    val role: String,
    val content: String,
)

@Serializable
data class ChatCompletionRequest(
    val model: String = MODEL_ID,
    val messages: List<ChatMessage>,
    val stream: Boolean = false,
    val temperature: Double? = null,
    @SerialName("max_tokens") val maxTokens: Int? = null,
    @SerialName("top_p") val topP: Double? = null,
    @SerialName("top_k") val topK: Int? = null,
)

@Serializable
data class Choice(
    val index: Int = 0,
    val message: ChatMessage,
    @SerialName("finish_reason") val finishReason: String? = "stop",
)

@Serializable
data class Usage(
    @SerialName("prompt_tokens") val promptTokens: Int = 0,
    @SerialName("completion_tokens") val completionTokens: Int = 0,
    @SerialName("total_tokens") val totalTokens: Int = 0,
)

@Serializable
data class ChatCompletionResponse(
    val id: String,
    @SerialName("object") val objectType: String = "chat.completion",
    val created: Long = System.currentTimeMillis() / 1000,
    val model: String = MODEL_ID,
    val choices: List<Choice>,
    val usage: Usage = Usage(),
)

@Serializable
data class Delta(
    val role: String? = null,
    val content: String? = null,
)

@Serializable
data class ChunkChoice(
    val index: Int = 0,
    val delta: Delta,
    @SerialName("finish_reason") val finishReason: String? = null,
)

@Serializable
data class ChatCompletionChunk(
    val id: String,
    @SerialName("object") val objectType: String = "chat.completion.chunk",
    val created: Long = System.currentTimeMillis() / 1000,
    val model: String = MODEL_ID,
    val choices: List<ChunkChoice>,
)

@Serializable
data class ModelInfo(
    val id: String,
    @SerialName("object") val objectType: String = "model",
    val created: Long = 1747872000L,
    @SerialName("owned_by") val ownedBy: String = "google",
)

@Serializable
data class ModelsResponse(
    @SerialName("object") val objectType: String = "list",
    val data: List<ModelInfo>,
)

@Serializable
data class ErrorDetail(val message: String, val type: String = "server_error", val code: String? = null)

@Serializable
data class ErrorResponse(val error: ErrorDetail)

// ── Engine initialisation ─────────────────────────────────────────────────────

val modelPath: String = args.firstOrNull()
    ?: System.getenv("LITERT_MODEL_PATH")
    ?: "${System.getProperty("user.home")}/$DEFAULT_MODEL_PATH"

val cacheDir: String = System.getenv("LITERT_CACHE_DIR")
    ?: "${System.getProperty("user.home")}/.cache/litert-lm"

File(cacheDir).mkdirs()

if (!File(modelPath).exists()) {
    System.err.println("ERROR: Model file not found: $modelPath")
    System.err.println("  • Pass model path as argument:  ./gemma-server.kts /path/to/model.litertlm")
    System.err.println("  • Or set env var:               export LITERT_MODEL_PATH=/path/to/model.litertlm")
    System.err.println("  • Download model:               https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm")
    exitProcess(1)
}

println("[INFO] Loading model: $modelPath")

var backendName = "GPU"
val engine: Engine = try {
    val cfg = EngineConfig(modelPath = modelPath, backend = Backend.GPU(), cacheDir = cacheDir)
    Engine(cfg).also {
        it.initialize()
        println("[INFO] GPU backend initialised successfully.")
    }
} catch (gpuError: Exception) {
    println("[WARN] GPU backend unavailable (${gpuError.message?.take(120)}) — falling back to CPU.")
    backendName = "CPU"
    try {
        val cfg = EngineConfig(modelPath = modelPath, backend = Backend.CPU(), cacheDir = cacheDir)
        Engine(cfg).also { it.initialize() }
    } catch (cpuError: Exception) {
        System.err.println("ERROR: Failed to initialise engine on CPU: ${cpuError.message}")
        System.err.println("  On Termux, litertlm-jvm native libs are compiled for Linux/glibc.")
        System.err.println("  Try running inside proot-distro (Ubuntu) for full compatibility.")
        exitProcess(1)
    }
}

println("[INFO] Model ready. Backend: $backendName | Model: $modelPath")

// Serialise inference requests — engine handles one at a time
val inferenceMutex = Mutex()

// ── Conversation builder ───────────────────────────────────────────────────────

fun buildConversationConfig(request: ChatCompletionRequest, historyMessages: List<ChatMessage>): ConversationConfig {
    val systemMsg = request.messages.firstOrNull { it.role == "system" }

    // Null-safe, non-nullable List<Message> as required by ConversationConfig
    val initialMessages: List<Message> = historyMessages.mapNotNull { msg ->
        when (msg.role) {
            "user" -> Message.user(msg.content)
            "assistant" -> Message.model(msg.content)
            else -> null
        }
    }

    return ConversationConfig(
        systemInstruction = systemMsg?.let { Contents.of(it.content) },
        initialMessages = initialMessages,
        samplerConfig = SamplerConfig(
            temperature = request.temperature ?: 1.0,
            topP = request.topP ?: 0.95,
            topK = request.topK ?: 40,
        ),
    )
}

// ── SSE helper ─────────────────────────────────────────────────────────────────

val sseContentType = ContentType("text", "event-stream")

fun sseData(payload: String): ByteArray = "data: $payload\n\n".toByteArray(Charsets.UTF_8)

// ── Ktor HTTP server ───────────────────────────────────────────────────────────

val server = embeddedServer(Netty, port = PORT, host = "0.0.0.0") {

    install(ContentNegotiation) { json(json) }

    install(CORS) {
        anyHost()
        allowHeader(HttpHeaders.ContentType)
        allowHeader(HttpHeaders.Authorization)
        allowMethod(HttpMethod.Options)
        allowMethod(HttpMethod.Get)
        allowMethod(HttpMethod.Post)
    }

    routing {

        // ── Health check ──────────────────────────────────────────────────────
        get("/health") {
            call.respond(
                mapOf(
                    "status" to "ok",
                    "model" to MODEL_ID,
                    "backend" to backendName,
                    "model_path" to modelPath,
                )
            )
        }

        // ── List models ───────────────────────────────────────────────────────
        get("/v1/models") {
            call.respond(ModelsResponse(data = listOf(ModelInfo(id = MODEL_ID))))
        }

        // ── Chat completions ──────────────────────────────────────────────────
        post("/v1/chat/completions") {
            val request = try {
                call.receive<ChatCompletionRequest>()
            } catch (e: Exception) {
                call.respond(
                    HttpStatusCode.BadRequest,
                    ErrorResponse(ErrorDetail("Invalid request body: ${e.message}", "invalid_request_error")),
                )
                return@post
            }

            if (request.messages.isEmpty()) {
                call.respond(
                    HttpStatusCode.BadRequest,
                    ErrorResponse(ErrorDetail("messages array must not be empty", "invalid_request_error")),
                )
                return@post
            }

            // Identify the last user turn and split history at that exact index.
            // Using indexOfLast avoids duplicating the prompt inside initialMessages
            // when the final turn is not a user message.
            val chatMessages = request.messages.filter { it.role != "system" }
            val lastUserIndex = chatMessages.indexOfLast { it.role == "user" }
            if (lastUserIndex < 0) {
                call.respond(
                    HttpStatusCode.BadRequest,
                    ErrorResponse(ErrorDetail("No user message found in messages array", "invalid_request_error")),
                )
                return@post
            }
            val lastUserMessage = chatMessages[lastUserIndex].content
            val historyMessages = chatMessages.take(lastUserIndex)

            val completionId = "chatcmpl-${UUID.randomUUID()}"
            val conversationConfig = buildConversationConfig(request, historyMessages)

            if (request.stream) {
                // ── Streaming (SSE) response ───────────────────────────────────
                call.response.header(HttpHeaders.CacheControl, "no-cache")
                call.response.header("X-Accel-Buffering", "no")
                call.response.header(HttpHeaders.Connection, "keep-alive")

                call.respondBytesWriter(contentType = sseContentType) {
                    val channel = this

                    try {
                        inferenceMutex.withLock {
                            engine.createConversation(conversationConfig).use { conversation ->
                                // Opening chunk — establishes the assistant role
                                channel.writeFully(
                                    sseData(
                                        json.encodeToString(
                                            ChatCompletionChunk(
                                                id = completionId,
                                                choices = listOf(ChunkChoice(delta = Delta(role = "assistant"))),
                                            )
                                        )
                                    )
                                )
                                channel.flush()

                                var hadError = false
                                conversation.sendMessageAsync(lastUserMessage)
                                    .catch { e ->
                                        hadError = true
                                        channel.writeFully(
                                            sseData("{\"error\":\"${e.message?.replace("\"", "\\\"").orEmpty()}\"}")
                                        )
                                        channel.flush()
                                    }
                                    .collect { message ->
                                        val text = message.toString()
                                        if (text.isNotEmpty()) {
                                            channel.writeFully(
                                                sseData(
                                                    json.encodeToString(
                                                        ChatCompletionChunk(
                                                            id = completionId,
                                                            choices = listOf(ChunkChoice(delta = Delta(content = text))),
                                                        )
                                                    )
                                                )
                                            )
                                            channel.flush()
                                        }
                                    }

                                if (!hadError) {
                                    // Closing chunk — signals end of stream
                                    channel.writeFully(
                                        sseData(
                                            json.encodeToString(
                                                ChatCompletionChunk(
                                                    id = completionId,
                                                    choices = listOf(ChunkChoice(delta = Delta(), finishReason = "stop")),
                                                )
                                            )
                                        )
                                    )
                                    channel.writeFully("data: [DONE]\n\n".toByteArray(Charsets.UTF_8))
                                    channel.flush()
                                }
                            }
                        }
                    } catch (e: Exception) {
                        val msg = e.message?.replace("\"", "\\\"").orEmpty()
                        channel.writeFully(sseData("{\"error\":\"$msg\"}"))
                        channel.flush()
                    }
                }
            } else {
                // ── Non-streaming response ─────────────────────────────────────
                try {
                    val fullText = StringBuilder()

                    inferenceMutex.withLock {
                        engine.createConversation(conversationConfig).use { conversation ->
                            conversation.sendMessageAsync(lastUserMessage).collect { message ->
                                fullText.append(message.toString())
                            }
                        }
                    }

                    call.respond(
                        ChatCompletionResponse(
                            id = completionId,
                            choices = listOf(
                                Choice(
                                    message = ChatMessage(role = "assistant", content = fullText.toString()),
                                )
                            ),
                        )
                    )
                } catch (e: Exception) {
                    call.respond(
                        HttpStatusCode.InternalServerError,
                        ErrorResponse(ErrorDetail(e.message ?: "Inference failed")),
                    )
                }
            }
        }

        // ── Legacy completions (delegates to chat) ────────────────────────────
        post("/v1/completions") {
            call.respond(
                HttpStatusCode.BadRequest,
                ErrorResponse(
                    ErrorDetail(
                        "Use /v1/chat/completions instead. Legacy text completions are not supported.",
                        "invalid_request_error",
                    )
                ),
            )
        }
    }
}

// ── Graceful shutdown ─────────────────────────────────────────────────────────

Runtime.getRuntime().addShutdownHook(
    Thread {
        println("\n[INFO] Shutting down server...")
        server.stop(gracePeriodMillis = 1_000L, timeoutMillis = 5_000L)
        engine.close()
        println("[INFO] Shutdown complete.")
    }
)

// ── Start ─────────────────────────────────────────────────────────────────────

println("[INFO] Gemma server listening on http://0.0.0.0:$PORT")
println("[INFO] Press Ctrl+C to stop.")
server.start(wait = true)
