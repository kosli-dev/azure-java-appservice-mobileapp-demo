package com.kosli.mobilepay

import android.os.Bundle
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val balance = TextView(this)
        balance.text = "Mobile Pay"
        setContentView(balance)
    }
}
