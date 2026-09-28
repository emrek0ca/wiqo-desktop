package com.wiqo.android.data.local

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Delete
import androidx.room.RoomDatabase
import kotlinx.coroutines.flow.Flow

@Entity(
    tableName = "conversation_messages",
    indices = [Index(value = ["accountId", "conversationId", "createdAt"])],
)
data class LocalConversationMessage(
    @PrimaryKey val id: String,
    val accountId: String,
    val conversationId: String,
    val role: String,
    val content: String,
    val createdAt: Long,
    val metadataJson: String? = null,
)

@Dao
interface LocalConversationDao {
    @Query("SELECT * FROM conversation_messages WHERE accountId = :accountId AND conversationId = :conversationId ORDER BY createdAt, id")
    fun observe(accountId: String, conversationId: String): Flow<List<LocalConversationMessage>>

    @Query("SELECT * FROM conversation_messages WHERE accountId = :accountId AND conversationId = :conversationId ORDER BY createdAt, id")
    suspend fun getMessages(accountId: String, conversationId: String): List<LocalConversationMessage>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(message: LocalConversationMessage)

    @Delete
    suspend fun delete(message: LocalConversationMessage)

    @Query("DELETE FROM conversation_messages WHERE accountId = :accountId")
    suspend fun clearAccount(accountId: String)
}

@Database(entities = [LocalConversationMessage::class], version = 2, exportSchema = true)
abstract class WiqoDatabase : RoomDatabase() {
    abstract fun conversations(): LocalConversationDao
}
