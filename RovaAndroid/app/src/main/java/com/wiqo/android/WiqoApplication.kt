package com.wiqo.android

import android.app.Application
import androidx.room.Room
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.wiqo.android.data.local.WiqoDatabase
import com.wiqo.android.data.local.UserPreferencesStore
import com.wiqo.android.data.network.WiqoApi
import com.wiqo.android.data.network.PushRegistration
import com.wiqo.android.data.security.SecureTokenStore
import com.wiqo.android.data.attachments.AttachmentLoader
import com.wiqo.android.data.attachments.DocumentContentLoader
import com.wiqo.android.data.artifacts.ArtifactRepository
import com.wiqo.android.data.billing.PlayBillingRepository

class WiqoApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        val tokenStore = SecureTokenStore(this)
        val api = WiqoApi(tokenStore)
        val database = Room.databaseBuilder(this, WiqoDatabase::class.java, "wiqo-local.db")
            .addMigrations(WIQO_DATABASE_MIGRATION_1_2)
            .build()
        val pushRegistration = PushRegistration(this, api)
        container = AppContainer(api, tokenStore, database, UserPreferencesStore(this), pushRegistration, AttachmentLoader(this), DocumentContentLoader(this), ArtifactRepository(this, api), PlayBillingRepository(this, api))
        if (tokenStore.read() != null) pushRegistration.register()
    }
}

private val WIQO_DATABASE_MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE conversation_messages ADD COLUMN metadataJson TEXT")
    }
}

data class AppContainer(
    val api: WiqoApi,
    val tokenStore: SecureTokenStore,
    val database: WiqoDatabase,
    val preferences: UserPreferencesStore,
    val pushRegistration: PushRegistration,
    val attachments: AttachmentLoader,
    val documents: DocumentContentLoader,
    val artifacts: ArtifactRepository,
    val billing: PlayBillingRepository,
)
